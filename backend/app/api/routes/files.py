from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.api.deps import get_db
from app.db import models
from app.schemas import FileListResponse, FileContentResponse
from app.services.workspaces import list_files, read_file, InvalidWorkspacePath

router = APIRouter()


@router.get("/{project_id}/files", response_model=FileListResponse)
def get_project_files(project_id: str, db: Session = Depends(get_db)):
    project = db.query(models.Project).filter(models.Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")
    files = list_files(project.workspace_path)
    return FileListResponse(files=files)


@router.get("/{project_id}/files/{file_path:path}", response_model=FileContentResponse)
def get_file_contents(project_id: str, file_path: str, db: Session = Depends(get_db)):
    project = db.query(models.Project).filter(models.Project.id == project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")
    try:
        contents = read_file(project.workspace_path, file_path)
    except InvalidWorkspacePath:
        raise HTTPException(status_code=400, detail="Invalid path")
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="File not found")
    return FileContentResponse(path=file_path, contents=contents)
