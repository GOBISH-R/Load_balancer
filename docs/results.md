# Failover Test Results

- **Run:** 2026-10-14 11:56:00 (local time)
- **Endpoint:** http://65.0.137.154/
- **Failure injected:** whole EC2 instance `backend-1` (i-0a4fcf6e6a18f160d) stopped with `aws ec2 stop-instances`
- **Instance fully stopped after:** 15 s
- **backend-1 serving again after start:** 20 s
- **Overall result:** **PASSED**

## Summary

| Phase | Requests | backend-1 | backend-2 | Failed | Avg ms | Max ms |
|---|---|---|---|---|---|---|
| 1. Baseline (both up) | 20 | 10 | 10 | 0 | 66 | 110 |
| 2. During shutdown | 20 | 1 | 19 | 0 | 80 | 96 |
| 3. Backend-1 stopped | 20 | 0 | 20 | 0 | 175 | 2071 |
| 4. During recovery | 34 | 1 | 33 | 0 | 104 | 1099 |
| 5. After recovery | 20 | 10 | 10 | 0 | 57 | 74 |

## Checks

- ✅ Baseline uses both backends
- ✅ No failed requests during shutdown
- ✅ All requests served by backend-2 while down
- ✅ No failed requests during recovery
- ✅ Both backends used again after recovery

## Notable requests

Requests that were retried on the other backend (two upstream addresses), slower than 1 s, or failed.

| Phase | Time | Status | Served by | Upstream tried | ms |
|---|---|---|---|---|---|
| 2. During shutdown | 11:56:04 | 200 | backend-2 | 10.0.1.11:5000, 10.0.1.12:5000 | 96 |
| 2. During shutdown | 11:56:07 | 200 | backend-2 | 10.0.1.11:5000, 10.0.1.12:5000 | 84 |
| 3. Backend-1 stopped | 11:56:18 | 200 | backend-2 | 10.0.1.11:5000, 10.0.1.12:5000 | 2071 |
| 4. During recovery | 11:56:31 | 200 | backend-2 | 10.0.1.11:5000, 10.0.1.12:5000 | 1099 |

Full per-request log: [failover-requests.csv](failover-requests.csv)
