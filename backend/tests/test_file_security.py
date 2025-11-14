import os
import sys
import json
import uuid
import shutil
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

# Ensure we can import "app.*" both locally and inside the backend container (mirror pattern from test_updated_at.py)
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
from app.services.workspaces import (  # noqa: E402
    safe_resolve_path,
    InvalidWorkspacePath,
    read_file as ws_read_file,
    list_files as ws_list_files,
)
from app.db.session import engine as app_engine, SessionLocal as AppSessionLocal  # noqa: E402


# (Removed) In-memory DB helpers; tests now use the application's engine/session


# (Removed) Dependency override helper; we initialize tables on the app engine instead


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


# -------------------------
# Unit tests: resolver rules
# -------------------------

def test_safe_resolve_path_rejects_absolute_and_traversal(tmp_path: Path):
    ws = tmp_path / "ws"
    ws.mkdir()

    # Absolute path
    with pytest.raises(InvalidWorkspacePath):
        safe_resolve_path(str(ws), "/etc/passwd")

    # Windows drive path patterns
    with pytest.raises(InvalidWorkspacePath):
        safe_resolve_path(str(ws), "C:\\Windows\\system32\\drivers\\etc\\hosts")
    with pytest.raises(InvalidWorkspacePath):
        safe_resolve_path(str(ws), "C:/Windows/system32/")

    # Traversal
    with pytest.raises(InvalidWorkspacePath):
        safe_resolve_path(str(ws), "../outside.txt")
    with pytest.raises(InvalidWorkspacePath):
        safe_resolve_path(str(ws), "../../etc/passwd")

    # Valid relative
    p = safe_resolve_path(str(ws), "index.html")
    assert str(p).startswith(str(ws))


def test_read_file_rejects_symlink_escape(tmp_path: Path):
    ws = tmp_path / "ws2"
    ws.mkdir()

    # Create a file outside
    outside_dir = tmp_path / "outside"
    outside_dir.mkdir()
    outside_file = outside_dir / "secret.txt"
    outside_file.write_text("top-secret", encoding="utf-8")

    # Symlink inside workspace pointing to outside
    leak = ws / "leak.txt"
    leak.symlink_to(outside_file)

    # Reading should raise InvalidWorkspacePath
    with pytest.raises(InvalidWorkspacePath):
        ws_read_file(str(ws), "leak.txt")

    # Now create a normal file and ensure reading works
    ok = ws / "index.html"
    ok.write_text("<html></html>", encoding="utf-8")
    assert ws_read_file(str(ws), "index.html") == "<html></html>"


def test_list_files_skips_symlink_escapes(tmp_path: Path):
    ws = tmp_path / "ws3"
    ws.mkdir()
    (ws / ".codex").mkdir()

    # Legit files
    (ws / "index.html").write_text("ok", encoding="utf-8")
    (ws / ".codex" / "result.json").write_text("{}", encoding="utf-8")

    # Create outside target
    outside_dir = tmp_path / "outside2"
    outside_dir.mkdir()
    outside_target = outside_dir / "data.txt"
    outside_target.write_text("outside", encoding="utf-8")

    # Symlink inside pointing outside
    (ws / "leak.txt").symlink_to(outside_target)

    files = ws_list_files(str(ws))
    paths = sorted(f["path"] for f in files)
    assert "index.html" in paths
    assert ".codex/result.json" in paths
    # Symlink escape must not appear
    assert "leak.txt" not in paths


# -------------------------
# API tests
# -------------------------

def test_files_api_valid_and_errors(tmp_path: Path):
    # Setup temp workspace with files
    ws = tmp_path / "ws_api"
    ws.mkdir()
    (ws / "index.html").write_text("<h1>Hello</h1>", encoding="utf-8")
    (ws / "style.css").write_text("body{}", encoding="utf-8")
    (ws / ".codex").mkdir()
    (ws / ".codex" / "result.json").write_text(json.dumps({"status": "ok"}), encoding="utf-8")

    # Outside file to simulate symlink escape
    outside_dir = tmp_path / "outside_api"
    outside_dir.mkdir()
    outside_file = outside_dir / "pw.txt"
    outside_file.write_text("pw", encoding="utf-8")

    # Create app and DB on the application's own engine/session
    Base.metadata.create_all(bind=app_engine)
    app = create_app()
    client = TestClient(app)

    # Create project
    db = AppSessionLocal()
    try:
        project = create_project_with_workspace(db, ws)
        pid = project.id
    finally:
        db.close()

    base = f"/api/v1/{pid}"

    # List files: expect index.html present and symlink not present
    resp = client.get(f"{base}/files")
    assert resp.status_code == 200, resp.text
    data = resp.json()
    names = sorted([f["path"] for f in data["files"]])
    assert "index.html" in names
    assert "style.css" in names
    assert ".codex/result.json" in names

    # Get valid file
    resp = client.get(f"{base}/files/index.html")
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["path"] == "index.html"
    assert "<h1>Hello</h1>" in body["contents"]

    # 404 for safe-but-missing
    resp = client.get(f"{base}/files/missing.txt")
    assert resp.status_code == 404

    # 400 for traversal attempts
    resp = client.get(f"{base}/files/../secret.txt")
    # Some HTTP clients normalize ".." segments before sending, which can bypass the route;
    # accept 404 (route not found) or 400 (server-side invalid path) for raw "..".
    assert resp.status_code in (400, 404)

    resp = client.get(f"{base}/files/../../etc/passwd")
    assert resp.status_code in (400, 404)

    # 400 for encoded traversal (%2e%2e = ..)
    resp = client.get(f"{base}/files/%2e%2e/secret.txt")
    assert resp.status_code == 400

    # 400 for encoded absolute path (%2Fetc%2Fpasswd = /etc/passwd)
    resp = client.get(f"{base}/files/%2Fetc%2Fpasswd")
    assert resp.status_code == 400

    # Symlink escape read: create symlink inside pointing to outside
    symlink_path = ws / "leak.txt"
    if symlink_path.exists() or symlink_path.is_symlink():
        symlink_path.unlink()
    symlink_path.symlink_to(outside_file)
    resp = client.get(f"{base}/files/leak.txt")
    assert resp.status_code == 400, f"Expected 400 for symlink escape, got {resp.status_code} {resp.text}"