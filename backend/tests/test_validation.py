import os
import sys
import uuid
from pathlib import Path

from fastapi.testclient import TestClient

# Ensure we can import "app.*" both locally and inside the backend container (mirror pattern from other tests)
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CANDIDATE_PATHS = [
    os.path.join(REPO_ROOT, "backend"),  # host repo layout
    REPO_ROOT,  # container layout where /app/app exists
]
for p in CANDIDATE_PATHS:
    if os.path.isdir(p) and p not in sys.path:
        sys.path.insert(0, p)

from backend.main import create_app  # noqa: E402
from app.db.models import Base  # noqa: E402
from app.db.session import engine as app_engine  # noqa: E402


def _client():
    Base.metadata.create_all(bind=app_engine)
    app = create_app()
    return TestClient(app)


def _create_project(client: TestClient) -> str:
    resp = client.post(
        "/api/v1/projects/",
        json={
            "instruction": "Generate a minimal Python CLI that prints the first 10 Fibonacci numbers and includes a basic test."
        },
    )
    assert resp.status_code == 200, resp.text
    return resp.json()["id"]


def _assert_422_shape(resp):
    assert resp.status_code == 422, resp.text
    body = resp.json()
    assert body["error"] == "validation_error"
    assert body["message"] == "Validation failed"
    assert body["code"] == 422
    assert isinstance(body.get("detail"), list)
    assert len(body["detail"]) >= 1
    return body


def test_project_instruction_too_short():
    client = _client()
    resp = client.post("/api/v1/projects/", json={"instruction": "abcd"})
    body = _assert_422_shape(resp)
    first = body["detail"][0]
    assert "loc" in first and first["loc"][-1] == "instruction"


def test_project_instruction_too_long():
    client = _client()
    long_text = "a" * 2001
    resp = client.post("/api/v1/projects/", json={"instruction": long_text})
    body = _assert_422_shape(resp)
    first = body["detail"][0]
    assert "loc" in first and first["loc"][-1] == "instruction"


def test_job_invalid_type():
    client = _client()
    pid = str(uuid.uuid4())  # body validation runs before handler; real project not required
    resp = client.post(
        f"/api/v1/{pid}/jobs",
        json={"job_type": "bogus", "instruction": "Do something"},
    )
    body = _assert_422_shape(resp)
    first = body["detail"][0]
    assert "loc" in first and first["loc"][-1] == "job_type"


def test_job_instruction_empty():
    client = _client()
    pid = str(uuid.uuid4())
    resp = client.post(
        f"/api/v1/{pid}/jobs",
        json={"job_type": "edit", "instruction": "   \t  \n"},
    )
    body = _assert_422_shape(resp)
    # Expect custom empty-after-trim message
    assert any("must not be empty" in item.get("msg", "") for item in body["detail"])


def test_valid_project_and_job():
    client = _client()
    pid = _create_project(client)
    # Happy path edit job
    resp = client.post(
        f"/api/v1/{pid}/jobs",
        json={"job_type": "edit", "instruction": "Append a comment line to app.py."},
    )
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["project_id"] == pid
    assert data["job_type"] == "edit"
    assert isinstance(data.get("id"), str) and len(data["id"]) > 0