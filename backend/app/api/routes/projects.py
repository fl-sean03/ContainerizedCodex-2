from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.api.deps import get_db
from app.core.logging import logger
from app.db import models
from app.schemas import ProjectCreate, ProjectSummary, ProjectDetail
from app.services.workspaces import create_workspace
from app.services.codex_runner import run_codex_job

router = APIRouter()



@router.post("/", response_model=ProjectSummary)
def create_project(payload: ProjectCreate, db: Session = Depends(get_db)):
    project = models.Project(
        instruction=payload.instruction,
        status="queued",
        workspace_path=str(create_workspace("temp")),  # temp; we fix ID after insert
    )
    db.add(project)
    db.commit()
    db.refresh(project)

    # Now fix workspace path to use actual project.id
    from app.services.workspaces import create_workspace as create_ws_again

    ws = create_ws_again(project.id)
    project.workspace_path = str(ws)
    db.add(project)
    db.commit()
    db.refresh(project)

    logger.info("Created project %s", project.id)

    # Create initial job
    job = models.Job(
        project_id=project.id,
        job_type="initial_project",
        instruction=payload.instruction,
        status="in_progress",
    )
    db.add(job)
    db.commit()
    db.refresh(job)

    # Run job synchronously (for skeleton). You can offload to background/queue later.
    run_codex_job(db, project, job)

    db.refresh(project)  # status might be updated by runner
    project.status = job.status
    project.summary = f"Initial job status: {job.status}"
    db.add(project)
    db.commit()
    db.refresh(project)

    return project


@router.get("/{project_id}", response_model=ProjectDetail)
def get_project(project_id: str, db: Session = Depends(get_db)):
    project = db.query(models.Project).filter(models.Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")

    return ProjectDetail(
        id=project.id,
        instruction=project.instruction,
        status=project.status,
        summary=project.summary,
        created_at=project.created_at,
        updated_at=project.updated_at,
        workspace_path=project.workspace_path,
        jobs=project.jobs,
    )
