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
from app.db.models import Base, Project  # noqa: E402
from app.db.session import engine as app_engine, SessionLocal as AppSessionLocal  # noqa: E402


def create_project_with_workspace(db, workspace: Path) -> Project:
    p = Project(
        instruction="Test project",
        status="completed",
        workspace_path=str(workspace),
    )
    db.add(p)
    db.commit()
    db.refresh(p)
    return p


def test_422_validation_error_on_projects_missing_field(tmp_path: Path):
    # Use the application's engine/session; ensure tables exist
    Base.metadata.create_all(bind=app_engine)
    app = create_app()
    client = TestClient(app)

    # Missing required field "instruction"
    resp = client.post("/api/v1/projects/", json={})
    assert resp.status_code == 422, resp.text

    body = resp.json()
    assert body["error"] == "validation_error"
    assert body["message"] == "Validation failed"
    assert body["code"] == 422
    assert isinstance(body.get("detail"), list)
    assert len(body["detail"]) >= 1
    # Validate shape of a typical error item
    first = body["detail"][0]
    assert "loc" in first and "msg" in first and "type" in first


def test_404_not_found_on_missing_project():
    Base.metadata.create_all(bind=app_engine)
    app = create_app()
    client = TestClient(app)

    resp = client.get(f"/api/v1/projects/{uuid.uuid4()}")
    assert resp.status_code == 404, resp.text

    body = resp.json()
    assert body["error"] == "not_found"
    assert body["message"] == "Not found"
    assert body["code"] == 404
    # Preserve original detail for compatibility
    assert body["detail"] == "Project not found"


def test_400_bad_request_on_invalid_absolute_path(tmp_path: Path):
    # Prepare a project and workspace
    ws = tmp_path / "ws_invalid_path"
    ws.mkdir()

    Base.metadata.create_all(bind=app_engine)
    app = create_app()
    client = TestClient(app)

    db = AppSessionLocal()
    try:
        project = create_project_with_workspace(db, ws)
        pid = project.id
    finally:
        db.close()

    # Encoded absolute path → should be rejected by files route as 400
    resp = client.get(f"/api/v1/{pid}/files/%2Fetc%2Fpasswd")
    assert resp.status_code == 400, resp.text

    body = resp.json()
    assert body["error"] == "bad_request"
    assert body["message"] == "Bad request"
    assert body["code"] == 400
    # Preserve original detail from HTTPException
    assert body["detail"] == "Invalid path"


def test_500_internal_error_from_unhandled_exception_route():
    Base.metadata.create_all(bind=app_engine)
    app = create_app()

    # Add a test-only route that raises Exception
    def boom():
        raise Exception("synthetic boom")

    app.add_api_route("/api/v1/test/boom", boom, methods=["GET"])

    client = TestClient(app, raise_server_exceptions=False)
    resp = client.get("/api/v1/test/boom")
    assert resp.status_code == 500, resp.text

    body = resp.json()
    assert body["error"] == "internal_error"
    assert body["message"] == "Internal server error"
    assert body["code"] == 500
    # Do not leak internal details
    assert "detail" not in body