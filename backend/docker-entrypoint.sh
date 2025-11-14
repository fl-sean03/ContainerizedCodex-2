#!/usr/bin/env sh
set -eu

cd /app
# Ensure Python can import the 'app' package (for Alembic env.py)
export PYTHONPATH="/app:${PYTHONPATH:-}"

echo "[entrypoint] Applying DB migrations..."
if [ -f "alembic.ini" ]; then
  # Prefer upgrade; if schema exists but not stamped, fall back to stamp.
  if alembic upgrade head; then
    echo "[entrypoint] alembic upgrade head succeeded."
  else
    echo "[entrypoint] alembic upgrade failed; attempting 'alembic stamp head'..."
    alembic stamp head || true
  fi
else
  echo "[entrypoint] alembic.ini not found; skipping migrations."
fi

echo "[entrypoint] Starting Uvicorn..."
exec uvicorn main:app --host 0.0.0.0 --port 8000