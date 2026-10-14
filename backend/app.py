"""Backend service for the Nginx reverse-proxy / load-balancer demo.

The same image runs on every backend instance; identity comes from env vars:
  SERVER_NAME   name shown in responses (e.g. backend-1)
  SERVER_COLOR  colour used for this backend in the dashboard
  PRIVATE_IP    instance private IP (injected by EC2 user-data)
  INSTANCE_ID   EC2 instance id (injected by EC2 user-data)
  AZ            availability zone (injected by EC2 user-data)
"""
import multiprocessing
import os
import socket
import time
from datetime import datetime, timezone

from flask import Flask, jsonify, render_template, request

app = Flask(__name__)

SERVER_NAME = os.getenv("SERVER_NAME", socket.gethostname())
SERVER_COLOR = os.getenv("SERVER_COLOR", "#2563eb")
PRIVATE_IP = os.getenv("PRIVATE_IP", "unknown")
INSTANCE_ID = os.getenv("INSTANCE_ID", "local")
AZ = os.getenv("AZ", "local")

# Upper bound for the simulated processing time a client may request via ?work=.
MAX_WORK_MS = 2000

STARTED_AT = datetime.now(timezone.utc)
_started_monotonic = time.monotonic()

# Shared memory counter: gunicorn runs with --preload, so it is created before the
# worker processes fork and every worker increments the same value.
_request_count = multiprocessing.Value("L", 0)


def _next_count():
    with _request_count.get_lock():
        _request_count.value += 1
        return _request_count.value


def _server_info(work_ms=0):
    return {
        "server": SERVER_NAME,
        "color": SERVER_COLOR,
        "hostname": socket.gethostname(),
        "private_ip": PRIVATE_IP,
        "instance_id": INSTANCE_ID,
        "availability_zone": AZ,
        "request_count": _next_count(),
        # Nginx sets X-Real-IP; fall back to the direct peer when hit locally.
        "client_ip": request.headers.get("X-Real-IP", request.remote_addr),
        "started_at": STARTED_AT.isoformat(timespec="seconds"),
        "uptime_seconds": int(time.monotonic() - _started_monotonic),
        "work_ms": work_ms,
        "timestamp": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }


@app.after_request
def add_headers(response):
    response.headers["X-Backend-Server"] = SERVER_NAME
    # Every dashboard poll must reach a backend, never a browser cache.
    if not request.path.startswith("/static/"):
        response.headers["Cache-Control"] = "no-store"
    return response


@app.route("/")
def index():
    # curl sends "*/*", which ties and resolves to the first option (JSON).
    best = request.accept_mimetypes.best_match(["application/json", "text/html"])
    if best == "text/html":
        return render_template("dashboard.html", server=SERVER_NAME, color=SERVER_COLOR)
    return jsonify(_server_info())


@app.route("/api")
def api():
    # Optional simulated processing time (?work=<ms>) so load tests can model slower requests.
    work_ms = max(0, min(request.args.get("work", default=0, type=int), MAX_WORK_MS))
    if work_ms:
        time.sleep(work_ms / 1000)
    return jsonify(_server_info(work_ms))


@app.route("/health")
def health():
    return jsonify(status="ok", server=SERVER_NAME)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "5000")))
