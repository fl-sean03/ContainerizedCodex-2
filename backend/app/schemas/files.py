from typing import List
from pydantic import BaseModel


class FileInfo(BaseModel):
    path: str
    size: int


class FileListResponse(BaseModel):
    files: List[FileInfo]


class FileContentResponse(BaseModel):
    path: str
    contents: str
