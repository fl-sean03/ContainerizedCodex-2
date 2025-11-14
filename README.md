# Codex Workspace Orchestrator

Natural-language → code-workspace orchestrator that uses a Codex worker (LLM-based coding agent)
inside an isolated container. The backend exposes a simple HTTP API for:

- Creating projects from natural language prompts.
- Listing and reading generated files.
- Submitting follow-up jobs (edits).

The skeleton includes:

- `backend/`: FastAPI app + SQLite + workspace manager.
- `worker/`: Container skeleton for a Codex worker, plus a dummy minimal Python CLI generator.
- `docker-compose.yml`: Local dev orchestration.

## Quickstart (dummy mode)

```bash
cp .env.example .env

docker-compose build
docker-compose up
```

Then:

- Backend is at `http://localhost:8000`
- Open `http://localhost:8000/docs` for interactive API docs.

## Example: create a project

```bash
curl -X POST http://localhost:8000/api/v1/projects   -H "Content-Type: application/json"   -d '{"instruction": "Generate a minimal Python CLI project that prints the first 10 Fibonacci numbers and includes a basic test."}'
```

In dummy mode, this will create a workspace with a minimal Python CLI Fibonacci example (README.md, app.py, tests/test_cli.py).

## Next steps

See `DEV_GUIDE.md` for detailed instructions on how to:

- Wire in the real Codex worker.
- Change storage / DB.
- Add auth, rate limits, etc.

---
## Default: Docker Compose (dummy mode)

This repo runs by default with Docker Compose in dummy mode. No real secrets are required and the worker is a stub that generates a minimal Python CLI project. See [docker-compose.yml](docker-compose.yml:1), [create_project()](backend/app/api/routes/projects.py:20), [files routes](backend/app/api/routes/files.py:12), and [jobs routes](backend/app/api/routes/jobs.py:12).

Quickstart
```bash
# 1) Create .env from example (do NOT use .env.live)
cp .env.example .env

# Ensure these values (already set in .env.example)
# USE_DUMMY_WORKER=True
# WORKSPACE_ROOT=./workspaces
# DATABASE_URL=sqlite:///./codex.db

# 2) Build & run
docker-compose build
docker-compose up
# Backend: http://localhost:8000
# Swagger: http://localhost:8000/docs
```

Notes
- POST /projects redirects with 307 if you omit the trailing slash. Use a trailing slash or curl -L. Example uses the trailing slash form /projects/.
- If port 8000 is busy, change ports in [docker-compose.yml](docker-compose.yml:7) from "8000:8000" to "8001:8000" and use http://localhost:8001.
- Workspaces are mounted host: ./backend/workspaces → container: /app/workspaces.

---

## API smoke tests (curl)

Base URL and trailing-slash-safe create call:
```bash
BASE=http://localhost:8000

# Create a project (trailing slash avoids 307)
RESP=$(curl -sSL -X POST "$BASE/api/v1/projects/" \
  -H "Content-Type: application/json" \
  -d '{"instruction":"Generate a minimal Python CLI project that prints the first 10 Fibonacci numbers and includes a basic test."}')

echo "$RESP" | sed -E 's/.{0}$//'
```

Capture project_id for subsequent calls:
```bash
PID=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
echo "PID=$PID"
```

List files (expect README.md, app.py, tests/test_cli.py and .codex/request.json, .codex/result.json):
```bash
curl -sS "$BASE/api/v1/$PID/files"
```

Fetch app.py (returns JSON with contents field):
```bash
curl -sS "$BASE/api/v1/$PID/files/app.py"
```

Add an edit job (dummy worker completes immediately):
```bash
curl -sS -X POST "$BASE/api/v1/$PID/jobs" \
  -H "Content-Type: application/json" \
  -d '{"job_type":"edit","instruction":"Append a comment line to app.py describing the change."}'
```

Optional: get project detail (includes workspace_path):
```bash
curl -sS "$BASE/api/v1/projects/$PID"
```

Filesystem validation (host volume):
```bash
ls -1 ./backend/workspaces/$PID
cat ./backend/workspaces/$PID/.codex/result.json
```

Expected outcomes
- POST /projects returns 200 JSON with status "completed".
- GET /{PID}/files includes: .codex/request.json, .codex/result.json, README.md, app.py, tests/test_cli.py.
- GET /{PID}/files/app.py returns JSON with a non-empty contents string.
- POST /{PID}/jobs (job_type=edit) returns 200 with status "completed".
- backend/workspaces/{PID}/.codex/result.json contains "status": "success" and created_files includes README.md, app.py, tests/test_cli.py.
The dummy worker behavior is implemented in [dummy_worker_generate_snake_game()](backend/app/services/codex_runner.py:29).

---
 
## Error Responses

All API errors return a standardized JSON payload via global handlers registered in [create_app()](backend/main.py:8). The schema is defined in [ErrorResponse](backend/app/schemas/errors.py:1) and handlers are implemented in [backend/app/core/errors.py](backend/app/core/errors.py:1).

Shape
- error: machine-readable string (e.g., "bad_request", "not_found", "validation_error", "internal_error")
- message: short human-readable summary
- code: HTTP status code
- detail: optional structured detail (e.g., validation errors or original message)
- correlation_id: optional string (reserved for future middleware; omitted/null for now)

Examples
- 400 Bad Request (invalid path)
  ```json
  {
    "error": "bad_request",
    "message": "Bad request",
    "code": 400,
    "detail": "Invalid path"
  }
  ```
- 404 Not Found (missing project)
  ```json
  {
    "error": "not_found",
    "message": "Not found",
    "code": 404,
    "detail": "Project not found"
  }
  ```
- 422 Validation Error (request body)
  ```json
  {
    "error": "validation_error",
    "message": "Validation failed",
    "code": 422,
    "detail": [
      { "loc": ["body", "instruction"], "msg": "Field required", "type": "missing" }
    ]
  }
  ```
- 500 Internal Server Error
  ```json
  {
    "error": "internal_error",
    "message": "Internal server error",
    "code": 500
  }
  ```

Notes
- Status codes for existing routes are preserved.
- Successful responses are unchanged.
- 4xx are logged at warning; 5xx at error with stack traces. See [backend/app/core/logging.py](backend/app/core/logging.py:1).

## Request Validation

Incoming request bodies are strictly validated by Pydantic models and surfaced via the global 422 handler [request_validation_error_handler()](backend/app/core/errors.py:50) with the standardized [ErrorResponse](backend/app/schemas/errors.py:25) shape.

Constraints
- [ProjectCreate](backend/app/schemas/projects.py:7)
  - instruction: trimmed string, min length 5, max length 2000. After trimming, it must not be empty (error message: "instruction must not be empty").
- [JobCreate](backend/app/schemas/jobs.py:13)
  - job_type: must be one of enum values in [JobType](backend/app/schemas/jobs.py:8) → "initial_project" | "edit"
  - instruction: trimmed string, min length 1, max length 2000. After trimming, it must not be empty (error message: "instruction must not be empty").

OpenAPI examples
- The request models include example payloads for better Swagger UX. See [ProjectCreate](backend/app/schemas/projects.py:7) and [JobCreate](backend/app/schemas/jobs.py:13).

Examples (curl)
- 422 Too short project instruction (min 5)
  ```bash
  curl -sS -X POST "$BASE/api/v1/projects/" \
    -H "Content-Type: application/json" \
    -d '{"instruction":"abcd"}'
  # → 422 with { "error":"validation_error", "message":"Validation failed", ... }
  ```
- 422 Whitespace-only job instruction (trimmed to empty)
  ```bash
  curl -sS -X POST "$BASE/api/v1/$PID/jobs" \
    -H "Content-Type: application/json" \
    -d '{"job_type":"edit","instruction":"   \t  "}'
  # → 422 with detail[].msg including "instruction must not be empty"
  ```
- 422 Invalid job_type (must be initial_project|edit)
  ```bash
  curl -sS -X POST "$BASE/api/v1/$PID/jobs" \
    -H "Content-Type: application/json" \
    -d '{"job_type":"bogus","instruction":"Do something"}'
  # → 422 validation_error
  ```
- 200 Valid payloads
  ```bash
  # Create project
  curl -sS -X POST "$BASE/api/v1/projects/" \
    -H "Content-Type: application/json" \
    -d '{"instruction":"Generate a minimal Python CLI that prints the first 10 Fibonacci numbers and includes a basic test."}'

  # Add edit job
  curl -sS -X POST "$BASE/api/v1/$PID/jobs" \
    -H "Content-Type: application/json" \
    -d '{"job_type":"edit","instruction":"Append a comment line to app.py describing the change."}'
  ```
## Troubleshooting

- 307 Temporary Redirect on POST /projects
  - Use the trailing slash path /api/v1/projects/ or curl with -L.

- Connection refused to http://localhost:8000
  - Ensure containers are running: docker ps
  - Check logs: docker logs codex-backend
  - If a different port is used, update BASE accordingly (e.g., 8001).

- Pydantic BaseSettings import error
  - The backend uses Pydantic v2 with pydantic-settings. This is already configured in [config.py](backend/app/core/config.py:1) and [backend/requirements.txt](backend/requirements.txt:1).

- Index HTML content looks empty
  - The endpoint returns JSON: { "path": "index.html", "contents": "..." }. Confirm contents length or pipe to a file before viewing.

- File permissions or missing workspace directory
  - Workspaces are created under WORKSPACE_ROOT and volume-mounted at runtime. See [workspaces.py](backend/app/services/workspaces.py:1). Ensure your host user has write permissions to ./backend/workspaces.

Security and hygiene
- Do not copy from .env.live. Keep USE_DUMMY_WORKER=True for dummy mode.
- .env and .env.live are ignored by git; see [.gitignore](.gitignore:1).

---

---
## Database migrations (Alembic)

This repo now uses Alembic migrations to manage the database schema.

Setup
- Install deps:
  ```bash
  pip install -r backend/requirements.txt
  ```
- Initialize or upgrade your DB:
  ```bash
  cd backend
  alembic upgrade head
  ```

Existing databases (same shape as current models)
- If you already have a DB that matches the current schema but is not stamped:
  ```bash
  cd backend
  alembic stamp head
  ```

Generating new migrations
- Edit models in `backend/app/db/models.py`.
- Autogenerate a revision:
  ```bash
  cd backend
  alembic revision --autogenerate -m "your message"
  alembic upgrade head
  ```

Runtime behavior
- The app no longer creates tables implicitly. The previous `Base.metadata.create_all(...)` call in the projects router has been removed.
- In Docker, migrations are applied automatically on backend container start via an entrypoint script. On a fresh DB this creates tables; on existing DBs with identical schema, it will stamp head if needed.
- For local (non-Docker) runs, run `alembic upgrade head` as shown above.

Verification
- A unit test asserts automatic `updated_at` behavior for both `Project` and `Job`:
  ```bash
  pytest backend/tests/test_updated_at.py -q
  ```

Notes
- Configure the database via `DATABASE_URL` (e.g., `sqlite:///./codex.db`). The Alembic environment reads this from the environment, falling back to the app settings default if unset.
- Migration files live under `backend/alembic/versions/`.

---
## Security: File Access

All file listing and reading APIs are sandboxed within each project's workspace directory. The backend enforces a strict path policy to prevent traversal and symlink escapes.

Policy
- Allowed
  - Relative paths that resolve to a location under the project workspace directory.
  - Hidden files and folders (including .codex) as long as they remain within the workspace.
- Blocked (400 Bad Request)
  - Absolute paths (e.g., /etc/passwd)
  - Windows drive or UNC-style paths (e.g., C:\Windows\..., \\server\share)
  - Traversal or escape attempts (e.g., ../outside.txt, ../../etc/passwd)
  - URL-encoded traversal or absolute paths (e.g., %2e%2e/, %2Fetc%2Fpasswd)
  - Symlinks that resolve to a target outside the workspace
- Safe but missing (404 Not Found)
  - Paths that are valid and inside the workspace but the file does not exist

Behavior by endpoint
- GET /api/v1/projects/{project_id}/files
  - Recursively lists files under the workspace.
  - Directory symlinks are not followed outside the workspace boundary.
  - Files whose real path resolves outside the workspace are skipped.
- GET /api/v1/projects/{project_id}/files/{path}
  - Returns file contents for a safe, existing file.
  - Returns 400 for invalid/unsafe paths (including symlink escapes).
  - Returns 404 for safe-but-nonexistent paths.

Implementation
- Centralized safe resolver and hardened file operations are implemented in:
  - [backend/app/services/workspaces.py](backend/app/services/workspaces.py)
  - [backend/app/api/routes/files.py](backend/app/api/routes/files.py)
- The resolver:
  - Joins the user-supplied path to the workspace root.
  - Rejects absolute/drive/UNC paths.
  - Resolves symlinks and checks the final real path remains within the workspace.
  - Uses non-strict resolution for existence checks, but still enforces boundary containment.

Examples
- Valid read
  - curl -sS "$BASE/api/v1/$PID/files/app.py"  # 200 with contents
- Invalid traversal
  - curl -sS "$BASE/api/v1/$PID/files/../secrets.txt"  # 400 Invalid path
  - curl -sS "$BASE/api/v1/$PID/files/%2e%2e/secrets.txt"  # 400 Invalid path
- Invalid absolute
  - curl -sS "$BASE/api/v1/$PID/files/%2Fetc%2Fpasswd"  # 400 Invalid path
- Nonexistent (safe)
  - curl -sS "$BASE/api/v1/$PID/files/does_not_exist.txt"  # 404 File not found

Notes
- This policy keeps existing successful behaviors for valid requests unchanged.
- The .codex directory is intentionally accessible to support worker I/O (request/result artifacts).

---
## CORS Configuration

The backend’s CORS policy is now environment-driven and defaults to safe local development values. Configuration is loaded via [Settings](backend/app/core/config.py:5) and applied in [create_app()](backend/main.py:15).

Environment keys (comma-separated lists supported)
- ALLOW_ORIGINS
- ALLOW_METHODS
- ALLOW_HEADERS
- ALLOW_CREDENTIALS (bool)

Defaults (safe for local dev)
- ALLOW_ORIGINS=http://localhost:3000,http://127.0.0.1:3000
- ALLOW_METHODS=GET,POST,PUT,DELETE,OPTIONS
- ALLOW_HEADERS=Authorization,Content-Type
- ALLOW_CREDENTIALS=False

Example .env (see [.env.example](.env.example:1))
```env
ALLOW_ORIGINS=http://localhost:3000,http://127.0.0.1:3000
ALLOW_METHODS=GET,POST,PUT,DELETE,OPTIONS
ALLOW_HEADERS=Authorization,Content-Type
ALLOW_CREDENTIALS=False
```

Allowing multiple origins
```env
ALLOW_ORIGINS=https://app.example.com,https://admin.example.com
```

Security notes
- Do not use "*" in production. Browsers disallow "*" with credentials.
- If ALLOW_CREDENTIALS=True, you must specify explicit origins (no "*"), and the middleware will echo the requesting allowed origin.
- Keep allowed methods/headers minimal to reduce attack surface.
- CORS is a browser protection; it does not replace server-side auth or authorization.

Implementation
- Typed, env-driven settings live in [Settings](backend/app/core/config.py:5) with robust CSV-to-list parsing.
- CORS middleware is wired in [create_app()](backend/main.py:15) using these settings at startup.

Tests
- Automated tests verify allowed vs blocked origins and preflight behavior. See [backend/tests/test_cors.py](backend/tests/test_cors.py:1).

---
## Live Validation Suite (real worker)

This suite validates the real worker container end-to-end with sequential, gated scenarios (L01–L08). It captures evidence under docs/evidence/&lt;timestamp&gt;/live/ per scenario and enforces presence-only secret handling.

Plan reference
- See the approved plan: [docs/plans/live-validation-suite-2025-11-14T17-14Z.md](docs/plans/live-validation-suite-2025-11-14T17-14Z.md)
- Core runner: [run_codex_job()](backend/app/services/codex_runner.py:95)
- Live worker entry: [main()](worker/run_codex_job.py:138)
- Orchestrator script: [tools/http/live_suite/run_all.sh](tools/http/live_suite/run_all.sh:1)
- Base live runner (L01–L06): [tools/http/live.sh](tools/http/live.sh:1)
- Evidence guide: [docs/evidence/README.md](docs/evidence/README.md)

Prerequisites
- USE_DUMMY_WORKER=False in [.env](.env)
- CODEX_WORKER_IMAGE points to a valid worker image (e.g., codex-worker:latest)
- .env.live includes OPENAI_API_KEY, OPENAI_ORG_ID, OPENAI_PROJECT (not committed; never printed)
- Backend can run docker (docker CLI in backend image and /var/run/docker.sock mounted)

Build the worker image
```bash
# From repo root
docker build -t codex-worker:latest -f worker/Dockerfile .
```

Run backend
```bash
docker-compose build
docker-compose up
# Swagger: http://localhost:8000/docs
```

Execute the live validation suite (gated L01–L08)
```bash
# From repo root
BASE_URL=http://localhost:8000 OUTROOT=docs/evidence bash tools/http/live_suite/run_all.sh
```

What the suite does
- L01: Confirms env passthrough; result.json logs include presence-only lines for OPENAI_*
- L02–L04: Verifies initial project artifacts and representative file reads
- L05–L06: Exercises edit flow (feature + refactor), checking modified_files and app.py content
- L07: Negative path; forces a structured error without crashing the system
- L08: Long-running behavior (polling with extended timeout), expects success or structured error
- Evidence is stored under docs/evidence/&lt;ISO8601Z&gt;/live/&lt;ScenarioID&gt;/

Evidence structure (examples)
- live/L01/response.json, project_id.txt, result.json, result_excerpt.txt
- live/L02/files.json
- live/L04/app.json
- live/L05/result.json, result_excerpt.txt
See: [docs/evidence/README.md](docs/evidence/README.md)

Secrets and hygiene
- Do not echo secrets; never store secret values in evidence
- Worker logs must indicate only presence/absence, enforced by [main()](worker/run_codex_job.py:138)
- .env and .env.live are ignored by VCS

Rollback to mocked (post-run)
```bash
# Switch back to dummy worker mode
# Edit .env:
#   USE_DUMMY_WORKER=True
docker-compose build
docker-compose up
# Optionally re-run mocked smoke tests M01–M04 as a sanity check
```

Troubleshooting
- 307 on POST /projects: use trailing path /api/v1/projects/
- Port conflict: change docker-compose to 8001:8000 and set BASE_URL=http://localhost:8001
- No result.json: check backend logs for docker run from [run_codex_job()](backend/app/services/codex_runner.py:95), and inspect workspace under ./backend/workspaces/&lt;project_id&gt;/.codex/
