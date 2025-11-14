from datetime import datetime
from typing import Optional, List, Annotated

from pydantic import BaseModel, ConfigDict, Field, field_validator


class ProjectCreate(BaseModel):
    instruction: Annotated[str, Field(min_length=5, max_length=2000)]

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
                    "instruction": "Generate a minimal Python CLI that prints the first 10 Fibonacci numbers and includes a basic test."
                }
            ]
        }
    )


class ProjectSummary(BaseModel):
    id: str
    instruction: str
    status: str
    summary: Optional[str] = None
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)


class ProjectDetail(ProjectSummary):
    workspace_path: str
    jobs: List["JobSummary"] = []  # defined in jobs.py via forward ref
