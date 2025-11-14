from fastapi import APIRouter

from . import projects, files, jobs

api_router = APIRouter()
api_router.include_router(projects.router, prefix="/projects", tags=["projects"])
api_router.include_router(files.router, tags=["files"])
api_router.include_router(jobs.router, tags=["jobs"])
