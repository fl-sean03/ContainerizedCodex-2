from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.api.deps import get_db
from app.db import models
from app.schemas import JobCreate, JobSummary, JobDetail
from app.services.codex_runner import run_codex_job

router = APIRouter()


@router.post("/{project_id}/jobs", response_model=JobSummary)
def create_job(project_id: str, payload: JobCreate, db: Session = Depends(get_db)):
    project = db.query(models.Project).filter(models.Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")

    job = models.Job(
        project_id=project.id,
        job_type=payload.job_type,
        instruction=payload.instruction,
        status="in_progress",
    )
    db.add(job)
    db.commit()
    db.refresh(job)

    run_codex_job(db, project, job)
    db.refresh(job)

    return job


@router.get("/{project_id}/jobs/{job_id}", response_model=JobDetail)
def get_job(project_id: str, job_id: str, db: Session = Depends(get_db)):
    job = db.query(models.Job).filter(
        models.Job.id == job_id, models.Job.project_id == project_id
    ).first()
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    return job
