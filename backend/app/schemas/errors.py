from typing import Any, Optional
from pydantic import BaseModel
from pydantic import ConfigDict


def error_slug_for_status(status_code: int) -> str:
    """Map HTTP status codes to canonical error slugs."""
    if status_code == 422:
        return "validation_error"
    if status_code == 404:
        return "not_found"
    if status_code == 400:
        return "bad_request"
    if status_code >= 500:
        return "internal_error"
    if status_code == 401:
        return "unauthorized"
    if status_code == 403:
        return "forbidden"
    if status_code == 409:
        return "conflict"
    return "http_error"


class ErrorResponse(BaseModel):
    """
    Canonical API error payload.
    - error: machine-readable category
    - message: short human-readable summary
    - code: HTTP status code
    - detail: optional structured details (e.g., validation errors)
    - correlation_id: reserved for future middleware (nullable/omitted)
    """

    error: str
    message: str
    code: int
    detail: Optional[Any] = None
    correlation_id: Optional[str] = None

    # Ignore unexpected fields; callers should use model_dump(exclude_none=True)
    model_config = ConfigDict(extra="ignore")