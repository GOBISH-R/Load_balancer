#!/usr/bin/env python3
"""Parallel load test through the Nginx load balancer (Python standard library only).

Examples:
  python scripts/load-test.py                      # 1,000 requests, 200 at a time
  python scripts/load-test.py -n 1000 -c 1000      # all 1,000 at once
  python scripts/load-test.py --work 200 --random  # each request does 0-200 ms of simulated work
  python scripts/load-test.py --duration 120 -c 100 --csv out.csv   # sustained load for 2 minutes
  python scripts/load-test.py --url http://1.2.3.4/
"""
import argparse
import csv
import http.client
import subprocess
import sys
import threading
import time
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from random import randint
from urllib.parse import urlsplit

TF_DIR = Path(__file__).resolve().parent.parent / "terraform"
TIMEOUT_S = 15
BUCKET_S = 5


@dataclass
class Result:
    status: int
    backend: str
    upstream: str
    ms: float
    finished: float = field(default_factory=time.time)  # wall-clock epoch seconds


def default_url():
    try:
        out = subprocess.run(
            ["terraform", f"-chdir={TF_DIR}", "output", "-raw", "app_url"],
            capture_output=True, text=True, check=True,
        )
        return out.stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        sys.exit("Could not read app_url from terraform output; pass --url.")


def one_request(host, port, path):
    # A fresh connection per request, like independent users hitting the site.
    started = time.perf_counter()
    conn = http.client.HTTPConnection(host, port, timeout=TIMEOUT_S)
    try:
        conn.request("GET", path, headers={"Accept": "application/json", "Connection": "close"})
        resp = conn.getresponse()
        resp.read()
        return Result(
            status=resp.status,
            backend=resp.getheader("X-Backend-Server", "-"),
            upstream=resp.getheader("X-Upstream-Addr", "-"),
            ms=(time.perf_counter() - started) * 1000,
        )
    except (OSError, http.client.HTTPException):
        return Result(0, "-", "-", (time.perf_counter() - started) * 1000)
    finally:
        conn.close()


def percentile(sorted_values, p):
    if not sorted_values:
        return 0.0
    k = max(0, min(len(sorted_values) - 1, -(-p * len(sorted_values) // 100) - 1))
    return sorted_values[int(k)]


def main():
    parser = argparse.ArgumentParser(description="Parallel load test through the Nginx load balancer.")
    parser.add_argument("--url", help="Load balancer URL (default: terraform output app_url)")
    parser.add_argument("-n", "--requests", type=int, default=1000, help="total requests (default 1000)")
    parser.add_argument("-c", "--concurrency", type=int, default=200, help="requests in flight at once (default 200)")
    parser.add_argument("--work", type=int, default=0, help="simulated processing time per request in ms")
    parser.add_argument("--random", action="store_true", help="use a random work time between 0 and --work")
    parser.add_argument("--duration", type=int, default=0,
                        help="keep sending for this many seconds instead of a fixed --requests count")
    parser.add_argument("--csv", help="write every request (time, status, backend, upstream, ms) to this file")
    args = parser.parse_args()

    url = args.url or default_url()
    parts = urlsplit(url)
    host, port = parts.hostname, parts.port or 80
    concurrency = max(1, args.concurrency if args.duration else min(args.concurrency, args.requests))

    def path_for_next():
        work = randint(0, args.work) if args.random else args.work
        return f"/api?work={work}" if work else "/api"

    work_desc = f"random 0-{args.work} ms" if args.random else f"{args.work} ms"
    amount = f"{args.duration} s of sustained load" if args.duration else f"{args.requests} requests"
    print(f"Load test: {amount}, {concurrency} at a time, work {work_desc} -> {url}")
    print(f"Started at {datetime.now():%H:%M:%S}", flush=True)

    done = 0
    lock = threading.Lock()

    def record(result, total_label):
        nonlocal done
        with lock:
            done += 1
            if done % 500 == 0:
                print(f"\r  progress: {done}/{total_label}", end="", flush=True)
        return result

    started = time.perf_counter()
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        if args.duration:
            deadline = started + args.duration

            def loop():
                out = []
                while time.perf_counter() < deadline:
                    out.append(record(one_request(host, port, path_for_next()), "?"))
                return out

            futures = [pool.submit(loop) for _ in range(concurrency)]
            results = [r for f in futures for r in f.result()]
        else:
            results = list(pool.map(
                lambda _: record(one_request(host, port, path_for_next()), args.requests),
                range(args.requests),
            ))
    elapsed = time.perf_counter() - started
    print()
    results.sort(key=lambda r: r.finished)

    ok = [r for r in results if r.status == 200]
    failed = len(results) - len(ok)
    retried = sum(1 for r in results if "," in r.upstream)
    statuses = Counter(r.status or "conn-error" for r in results)
    split = Counter(r.backend for r in ok)
    lat = sorted(r.ms for r in results)

    print("\nResults")
    print(f"  Duration      {elapsed:.2f} s")
    print(f"  Throughput    {len(results) / elapsed:.1f} requests/s")
    print(f"  Succeeded     {len(ok)}")
    print(f"  Failed        {failed}")
    print(f"  Retried       {retried}  (Nginx tried one backend, then answered from the other)")
    print(f"  Status codes  " + ", ".join(f"{k}={v}" for k, v in sorted(statuses.items(), key=str)))
    print("\nDistribution")
    for name in sorted(split):
        share = split[name] / len(ok) * 100
        print(f"  {name:<10} {split[name]:>6}  {share:5.1f}%  {'#' * round(share / 2)}")
    print("\nLatency (ms)")
    print(f"  min {lat[0]:.0f}   p50 {percentile(lat, 50):.0f}   p95 {percentile(lat, 95):.0f}"
          f"   p99 {percentile(lat, 99):.0f}   max {lat[-1]:.0f}")

    if elapsed >= 2 * BUCKET_S:
        print_timeline(results, sorted(split))

    if args.csv:
        with open(args.csv, "w", newline="", encoding="utf-8") as fh:
            writer = csv.writer(fh)
            writer.writerow(["finished", "status", "backend", "upstream", "ms"])
            for r in results:
                writer.writerow([datetime.fromtimestamp(r.finished).strftime("%H:%M:%S.%f")[:-3],
                                 r.status, r.backend, r.upstream, round(r.ms)])
        print(f"\nPer-request log written to {args.csv}")

    return 1 if failed else 0


def print_timeline(results, backends):
    """Requests per backend in fixed wall-clock windows, to show traffic shifting during a failure."""
    buckets = defaultdict(Counter)
    for r in results:
        key = int(r.finished // BUCKET_S) * BUCKET_S
        c = buckets[key]
        c[r.backend if r.status == 200 else "failed"] += 1
        if "," in r.upstream:
            c["retried"] += 1
    print(f"\nTimeline ({BUCKET_S}-second windows)")
    header = "  " + "window".ljust(10) + "".join(f"{b:>11}" for b in backends) + f"{'failed':>9}{'retried':>9}"
    print(header)
    for key in sorted(buckets):
        c = buckets[key]
        row = "  " + datetime.fromtimestamp(key).strftime("%H:%M:%S").ljust(10)
        row += "".join(f"{c[b]:>11}" for b in backends) + f"{c['failed']:>9}{c['retried']:>9}"
        print(row)


if __name__ == "__main__":
    sys.exit(main())
