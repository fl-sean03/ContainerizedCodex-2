import os
import sys
import time
from datetime import datetime

from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

# Ensure we can import "app.*" both locally and inside the backend container
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CANDIDATE_PATHS = [
    os.path.join(REPO_ROOT, "backend"),  # host repo layout
    REPO_ROOT,  # container layout where /app/app exists
]
for p in CANDIDATE_PATHS:
    if os.path.isdir(p) and p not in sys.path:
        sys.path.insert(0, p)

from app.db.models import Base, Project, Job  # noqa: E402


def make_session():
    engine = create_engine("sqlite:///:memory:", connect_args={"check_same_thread": False})
    Base.metadata.create_all(bind=engine)
    return sessionmaker(autocommit=False, autoflush=False, bind=engine)()


def test_project_updated_at_increases_on_update():
    db = make_session()
    try:
        p = Project(instruction="Test project", status="queued", workspace_path="/tmp/ws")
        db.add(p)
        db.commit()
        db.refresh(p)
        t1 = p.updated_at

        # Ensure clock tick difference is observable
        time.sleep(1.1)

        p.summary = "Updated summary"
        db.add(p)
        db.commit()
        db.refresh(p)
        t2 = p.updated_at

        assert t2 > t1, f"Project.updated_at did not increase: before={t1}, after={t2}"
    finally:
        db.close()


def test_job_updated_at_increases_on_update():
    db = make_session()
    try:
        # Need a project first due to FK
        p = Project(instruction="Test", status="queued", workspace_path="/tmp/ws")
        db.add(p)
        db.commit()
        db.refresh(p)

        j = Job(
            project_id=p.id,
            job_type="initial_project",
            instruction="Do something",
            status="queued",
        )
        db.add(j)
        db.commit()
        db.refresh(j)
        t1 = j.updated_at

        time.sleep(1.1)

        j.status = "in_progress"
        db.add(j)
        db.commit()
        db.refresh(j)
        t2 = j.updated_at

        assert t2 > t1, f"Job.updated_at did not increase: before={t1}, after={t2}"
    finally:
        db.close()