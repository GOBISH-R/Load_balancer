# Failover Under Load

- **Endpoint:** http://65.0.137.154/
- **Load:** 100 concurrent clients for 150 s (`scripts/load-test.py`)
- **Failure injected:** whole EC2 instance `backend-1` (i-066553872430b2430) stopped, then started again
- **Result:** **PASSED (0 failed requests)**

## Events

| Time | Event |
|---|---|
| 13:41:07 | Load test started (100 concurrent clients, 150 s) |
| 13:41:24 | Stop issued for the backend-1 EC2 instance |
| 13:41:44 | backend-1 instance fully stopped |
| 13:42:02 | Start issued for the backend-1 EC2 instance |
| 13:42:06 | backend-1 instance running (booting, container starting) |
| 13:42:26 | backend-1 serving traffic again (Nginx put it back in rotation) |
| 13:43:39 | Load test finished |

## Load test output

Read the timeline next to the event times: backend-1 drops to 0 while it is stopped, backend-2 takes
all traffic, and the failed column stays at 0. "retried" counts requests Nginx re-sent to the other
backend after the first one did not answer.

```text
Load test: 150 s of sustained load, 100 at a time, work 0 ms -> http://65.0.137.154/
Started at 13:41:07


Results
  Duration      150.90 s
  Throughput    672.8 requests/s
  Succeeded     101521
  Failed        0
  Retried       17  (Nginx tried one backend, then answered from the other)
  Status codes  200=101521

Distribution
  backend-1   31425   31.0%  ###############
  backend-2   70096   69.0%  ###################################

Latency (ms)
  min 37   p50 60   p95 1056   p99 1138   max 7104

Timeline (5-second windows)
  window      backend-1  backend-2   failed  retried
  13:41:05          692        690        0        0
  13:41:10         1629       1632        0        0
  13:41:15         1534       1533        0        0
  13:41:20         1895       1909        0        0
  13:41:25            9       4001        0        8
  13:41:30            0       3347        0        0
  13:41:35            0       3509        0        2
  13:41:40            0       3264        0        0
  13:41:45            0       2802        0        0
  13:41:50            0       2702        0        2
  13:41:55            0       3108        0        0
  13:42:00            0       3311        0        2
  13:42:05            0       3203        0        0
  13:42:10            0       2943        0        2
  13:42:15            0       2937        0        0
  13:42:20            0       3240        0        0
  13:42:25         1256       1556        0        0
  13:42:30         1270       1274        0        0
  13:42:35         1717       1713        0        0
  13:42:40         1613       1613        0        0
  13:42:45         1631       1632        0        0
  13:42:50         1627       1626        0        0
  13:42:55         1961       1961        0        0
  13:43:00         1755       1756        0        0
  13:43:05         1839       1837        0        1
  13:43:10         2030       2031        0        0
  13:43:15         1905       1901        0        0
  13:43:20         1963       1966        0        0
  13:43:25         1987       1986        0        0
  13:43:30         1928       1930        0        0
  13:43:35         1184       1183        0        0

Per-request log written to D:\DevOps\reverse-proxy-lb\scripts\..\docs\failover-under-load.csv
```

Per-request log: [failover-under-load.csv](failover-under-load.csv)
