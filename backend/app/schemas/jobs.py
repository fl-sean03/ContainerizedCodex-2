from datetime import datetime
from typing import Optional, Annotated
from enum import Enum

from pydantic import BaseModel, ConfigDict, Field, field_validator


class JobType(str, Enum):
    initial_project = "initial_project"
    edit = "edit"


class JobCreate(BaseModel):
    job_type: JobType  # restricted enum
    instruction: Annotated[str, Field(min_length=1, max_length=2000)]

    @field_validator("instruction", mode="before")
    @classmethod
    def _trim_and_require_non_empty(cls, v):
        if v is None:
            return v
        if isinstance(v, str):
            v = v.strip()
            if v == "":
                raise ValueError("instruction must not be empty")
        return v

    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "job_type": "initial_project",
                    "instruction": "Generate a minimal Python CLI that prints the first 10 Fibonacci numbers and includes a basic test."
                },
                {
                    "job_type": "edit",
                    "instruction": "Append a comment line to app.py describing the change."
                },
            ]
        }
    )


class JobSummary(BaseModel):
    id: str
    project_id: str
    job_type: str
    instruction: str
    status: str
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)


class JobDetail(JobSummary):
    result_path: Optional[str] = None
    logs_path: Optional[str] = None
