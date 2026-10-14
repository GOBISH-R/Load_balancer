import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.environ["SERVER_NAME"] = "backend-test"

import app as backend  # noqa: E402

client = backend.app.test_client()


def test_root_returns_json_for_curl():
    resp = client.get("/", headers={"Accept": "*/*"})
    assert resp.status_code == 200
    assert resp.is_json
    assert resp.get_json()["server"] == "backend-test"
    assert resp.headers["X-Backend-Server"] == "backend-test"


def test_root_returns_html_for_browser():
    accept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    resp = client.get("/", headers={"Accept": accept})
    assert resp.status_code == 200
    assert resp.mimetype == "text/html"
    assert b"Load Balancer Live Dashboard" in resp.data
    assert b"backend-test" in resp.data


def test_dashboard_assets_are_served():
    for path in ("/static/dashboard.js", "/static/dashboard.css"):
        resp = client.get(path)
        assert resp.status_code == 200, path
        resp.close()


def test_api_is_never_cached():
    resp = client.get("/api")
    assert resp.headers["Cache-Control"] == "no-store"
    info = resp.get_json()
    assert {"color", "started_at", "uptime_seconds"} <= info.keys()


def test_health():
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "ok"


def test_request_counter_increments():
    first = client.get("/api").get_json()["request_count"]
    second = client.get("/api").get_json()["request_count"]
    assert second == first + 1


def test_simulated_work_is_applied_and_clamped():
    assert client.get("/api?work=30").get_json()["work_ms"] == 30
    assert client.get("/api?work=-5").get_json()["work_ms"] == 0
    assert client.get("/api?work=abc").get_json()["work_ms"] == 0
    # Clamped values are reported without actually sleeping for the requested time.
    backend.MAX_WORK_MS, original = 10, backend.MAX_WORK_MS
    try:
        assert client.get("/api?work=999999").get_json()["work_ms"] == 10
    finally:
        backend.MAX_WORK_MS = original


def test_client_ip_uses_x_real_ip():
    resp = client.get("/api", headers={"X-Real-IP": "203.0.113.7"})
    assert resp.get_json()["client_ip"] == "203.0.113.7"
