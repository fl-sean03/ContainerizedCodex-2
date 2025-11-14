from typing import Any, Dict, Optional

from fastapi import Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.core.logging import logger
from app.schemas.errors import ErrorResponse, error_slug_for_status


_STATUS_MESSAGES: Dict[int, str] = {
    400: "Bad request",
    401: "Unauthorized",
    403: "Forbidden",
    404: "Not found",
    409: "Conflict",
    422: "Validation failed",
}
_DEFAULT_4XX_MESSAGE = "HTTP error"
_DEFAULT_5XX_MESSAGE = "Internal server error"


def _status_message(code: int) -> str:
    if code >= 500:
        return _DEFAULT_5XX_MESSAGE
    return _STATUS_MESSAGES.get(code, _DEFAULT_4XX_MESSAGE)


def _build_error_response(
    *,
    request: Request,
    status_code: int,
    message: Optional[str] = None,
    detail: Optional[Any] = None,
    correlation_id: Optional[str] = None,
) -> JSONResponse:
    error_slug = error_slug_for_status(status_code)
    msg = message or _status_message(status_code)
    payload = ErrorResponse(
        error=error_slug,
        message=msg,
        code=status_code,
        detail=detail,
        correlation_id=correlation_id,
    ).model_dump(exclude_none=True)
    return JSONResponse(status_code=status_code, content=payload, media_type="application/json")


def _sanitize_validation_detail(detail: Any) -> Any:
    """
    Ensure validation detail is JSON-serializable.
    Pydantic may include an Exception instance in ctx.error; convert to str.
    """
    if isinstance(detail, list):
        sanitized = []
        for item in detail:
            if isinstance(item, dict):
                ctx = item.get("ctx")
                if isinstance(ctx, dict) and "error" in ctx and isinstance(ctx["error"], BaseException):
                    # Copy to avoid mutating original structures unexpectedly
                    new_item = dict(item)
                    new_ctx = dict(ctx)
                    new_ctx["error"] = str(ctx["error"])
                    new_item["ctx"] = new_ctx
                    sanitized.append(new_item)
                    continue
            sanitized.append(item)
        return sanitized
    return detail


async def request_validation_error_handler(request: Request, exc: RequestValidationError) -> JSONResponse:
    status_code = 422
    # FastAPI/Starlette provide a list of validation issues
    detail = _sanitize_validation_detail(exc.errors())
    # Log warning with method and path
    logger.warning(
        "Validation error: %s %s status=%s issues=%d",
        request.method,
        request.url.path,
        status_code,
        len(detail) if isinstance(detail, list) else 1,
    )
    return _build_error_response(
        request=request,
        status_code=status_code,
        message=_STATUS_MESSAGES.get(422, "Validation failed"),
        detail=detail,
    )


async def http_exception_handler(request: Request, exc: StarletteHTTPException) -> JSONResponse:
    status_code = exc.status_code
    detail = getattr(exc, "detail", None)
    # Warning-level log for 4xx; Error for 5xx (rare for HTTPException, but guard anyway)
    if 400 <= status_code < 500:
        logger.warning(
            "HTTPException: %s %s status=%s error=%s detail=%r",
            request.method,
            request.url.path,
            status_code,
            error_slug_for_status(status_code),
            detail,
        )
    else:
        logger.error(
            "HTTPException-5xx: %s %s status=%s error=%s detail=%r",
            request.method,
            request.url.path,
            status_code,
            error_slug_for_status(status_code),
            detail,
        )
    return _build_error_response(
        request=request,
        status_code=status_code,
        message=_status_message(status_code),
        detail=detail,
    )


async def unhandled_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    status_code = 500
    # Error log with stack trace
    logger.error(
        "Unhandled exception: %s %s status=%s",
        request.method,
        request.url.path,
        status_code,
        exc_info=True,
    )
    return _build_error_response(
        request=request,
        status_code=status_code,
        message=_DEFAULT_5XX_MESSAGE,
        detail=None,  # do not leak server internals
    )