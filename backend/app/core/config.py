import os
from typing import Any, List
from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict
from pydantic_settings.sources import EnvSettingsSource


class CSVFirstEnvSource(EnvSettingsSource):
    def decode_complex_value(self, field_name, field, value):
        # For our CSV-driven list fields, skip JSON decoding so validators can parse CSV
        if isinstance(value, str) and field_name in {"ALLOW_ORIGINS", "ALLOW_METHODS", "ALLOW_HEADERS"}:
            return value
        return super().decode_complex_value(field_name, field, value)


class Settings(BaseSettings):
    # FastAPI
    APP_NAME: str = "Codex Workspace Orchestrator"
    API_V1_STR: str = "/api/v1"

    # DB
    DATABASE_URL: str = "sqlite:///./codex.db"

    # Workspaces
    WORKSPACE_ROOT: str = "./workspaces"

    # Worker behavior
    USE_DUMMY_WORKER: bool = True  # Toggle this off when you wire real Codex
    CODEX_WORKER_IMAGE: str = "codex-worker:latest"

    # CORS (env-driven)
    # Comma-separated values supported (e.g., "http://localhost:3000,http://127.0.0.1:3000")
    ALLOW_ORIGINS: List[str] = ["http://localhost:3000", "http://127.0.0.1:3000"]
    ALLOW_METHODS: List[str] = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
    ALLOW_HEADERS: List[str] = ["Authorization", "Content-Type"]
    ALLOW_CREDENTIALS: bool = False

    @staticmethod
    def _parse_csv_list(v: Any):
        """
        Accepts:
        - comma-separated string -> ["a","b"]
        - list/tuple/set -> coerced to list of trimmed strings
        - empty/whitespace string -> []
        - None/other -> passthrough
        """
        if v is None:
            return v
        if isinstance(v, str):
            s = v.strip()
            if not s:
                return []
            return [part.strip() for part in s.split(",") if part.strip()]
        if isinstance(v, (list, tuple, set)):
            return [str(part).strip() for part in v if str(part).strip()]
        return v

    @field_validator("ALLOW_ORIGINS", "ALLOW_METHODS", "ALLOW_HEADERS", mode="before")
    @classmethod
    def _coerce_csv_lists(cls, v: Any):
        return cls._parse_csv_list(v)

    @classmethod
    def settings_customise_sources(
        cls,
        settings_cls,
        init_settings,
        env_settings,
        dotenv_settings,
        file_secret_settings,
    ):
        # Prefer a custom Env source that leaves CSV strings intact for list fields,
        # letting our field_validator parse comma-separated values.
        return (
            init_settings,
            CSVFirstEnvSource(settings_cls),
            dotenv_settings,
            file_secret_settings,
        )

    model_config = SettingsConfigDict(
        env_file=".env",
    )


settings = Settings()
