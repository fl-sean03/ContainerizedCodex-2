import os
import sys
import importlib
from typing import Dict
from fastapi.testclient import TestClient

# Ensure we can import "app.*" and "backend.*" both locally and inside the backend container
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CANDIDATE_PATHS = [
    os.path.join(REPO_ROOT, "backend"),  # host repo layout
    REPO_ROOT,  # container layout where /app/app exists
]
for p in CANDIDATE_PATHS:
    if os.path.isdir(p) and p not in sys.path:
        sys.path.insert(0, p)


def build_app_with_env(monkeypatch, env: Dict[str, str]):
    # Set environment for this test
    for k, v in env.items():
        monkeypatch.setenv(k, v)

    # Reload settings and app to pick up env changes
    import app.core.config as cfg
    importlib.reload(cfg)

    import backend.main as backend_main
    importlib.reload(backend_main)

    # Build fresh app instance using current settings
    return backend_main.create_app()


def test_allowed_origin_simple(monkeypatch):
    app = build_app_with_env(
        monkeypatch,
        {
            "ALLOW_ORIGINS": "http://good.test",
            "ALLOW_METHODS": "GET,POST,OPTIONS",
            "ALLOW_HEADERS": "Authorization,Content-Type",
            "ALLOW_CREDENTIALS": "False",
        },
    )
    client = TestClient(app)

    resp = client.get("/openapi.json", headers={"Origin": "http://good.test"})
    # openapi.json should exist on FastAPI by default
    assert resp.status_code == 200
    assert resp.headers.get("access-control-allow-origin") == "http://good.test"


def test_blocked_origin_simple(monkeypatch):
    app = build_app_with_env(
        monkeypatch,
        {
            "ALLOW_ORIGINS": "http://good.test",
            "ALLOW_METHODS": "GET,POST,OPTIONS",
            "ALLOW_HEADERS": "Authorization,Content-Type",
            "ALLOW_CREDENTIALS": "False",
        },
    )
    client = TestClient(app)

    resp = client.get("/openapi.json", headers={"Origin": "http://evil.test"})
    assert resp.status_code == 200
    # For blocked origins, the CORS allow header should be absent
    assert resp.headers.get("access-control-allow-origin") is None


def test_preflight_allowed(monkeypatch):
    app = build_app_with_env(
        monkeypatch,
        {
            "ALLOW_ORIGINS": "http://good.test",
            "ALLOW_METHODS": "GET,POST,OPTIONS",
            "ALLOW_HEADERS": "Authorization,Content-Type,X-Custom-Header",
            "ALLOW_CREDENTIALS": "True",
        },
    )
    client = TestClient(app)

    resp = client.options(
        "/openapi.json",
        headers={
            "Origin": "http://good.test",
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "Authorization, X-Custom-Header",
        },
    )

    # Starlette CORSMiddleware should handle preflight and return 200
    assert resp.status_code == 200
    headers_lower = {k.lower(): v for k, v in resp.headers.items()}

    assert headers_lower.get("access-control-allow-origin") == "http://good.test"
    assert "post" in (headers_lower.get("access-control-allow-methods", "")).lower()

    allow_headers = (headers_lower.get("access-control-allow-headers", "")).lower()
    assert "authorization" in allow_headers
    assert "x-custom-header" in allow_headers

    # With ALLOW_CREDENTIALS=True, expect the header value "true"
    assert headers_lower.get("access-control-allow-credentials") == "true"


def test_preflight_blocked(monkeypatch):
    app = build_app_with_env(
        monkeypatch,
        {
            "ALLOW_ORIGINS": "http://good.test",
            "ALLOW_METHODS": "GET,POST,OPTIONS",
            "ALLOW_HEADERS": "Authorization,Content-Type",
            "ALLOW_CREDENTIALS": "False",
        },
    )
    client = TestClient(app)

    resp = client.options(
        "/openapi.json",
        headers={
            "Origin": "http://evil.test",
            "Access-Control-Request-Method": "GET",
        },
    )

    # Disallowed origin preflight should not be authorized by CORS
    # Starlette returns 400 and does not echo the Origin in Access-Control-Allow-Origin
    assert resp.status_code == 400
    assert resp.headers.get("access-control-allow-origin") is None