import uuid
from datetime import datetime

from sqlalchemy import Column, DateTime, String, Text, ForeignKey, event
from sqlalchemy.orm import declarative_base, relationship

Base = declarative_base()


def generate_uuid() -> str:
    return str(uuid.uuid4())


class Project(Base):
    __tablename__ = "projects"

    id = Column(String, primary_key=True, default=generate_uuid)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow, nullable=False)

    instruction = Column(Text, nullable=False)
    status = Column(String, default="queued", nullable=False)  # queued|in_progress|completed|error
    summary = Column(Text, nullable=True)

    workspace_path = Column(String, nullable=False)

    jobs = relationship("Job", back_populates="project")


class Job(Base):
    __tablename__ = "jobs"

    id = Column(String, primary_key=True, default=generate_uuid)
    project_id = Column(String, ForeignKey("projects.id"), nullable=False)

    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow, nullable=False)

    job_type = Column(String, nullable=False)  # initial_project | edit
    instruction = Column(Text, nullable=False)
    status = Column(String, default="queued", nullable=False)  # queued|in_progress|completed|error

    result_path = Column(String, nullable=True)  # path to .result.json if any
    logs_path = Column(String, nullable=True)

    project = relationship("Project", back_populates="jobs")


# SQLAlchemy events to ensure updated_at bumps on UPDATE operations
@event.listens_for(Project, "before_update", propagate=True)
def project_before_update(mapper, connection, target):
    target.updated_at = datetime.utcnow()


@event.listens_for(Job, "before_update", propagate=True)
def job_before_update(mapper, connection, target):
    target.updated_at = datetime.utcnow()
