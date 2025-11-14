# Developer Guide – Codex Workspace Orchestrator

This guide explains:

1. Architecture
2. Data model
3. Execution flow (end-to-end)
4. How to run locally
5. How to replace the dummy worker with a real Codex worker
6. Where to extend / customize

---

## 1. Architecture

### Components

- **Backend (FastAPI)**  
  Exposes HTTP API. Manages projects, jobs, and workspaces. Orchestrates worker containers.

- **Workspace storage**  
  Each project has a directory under `WORKSPACE_ROOT` (default `./backend/workspaces`).
  Worker containers mount this directory and read/write files there.

- **Codex worker container**  
  Runs inside Docker. Receives `.codex/request.json` and writes `.codex/result.json`,
  plus any code files. Skeleton has a stub; you will replace it with Codex CLI integration.

- **DB (SQLite)**  
  Two tables:
  - `projects`: high-level info per project
  - `jobs`: individual jobs (initial generation + edits)

---

## 2. Data model

### Project

- `id` (UUID string)
- `instruction` (initial natural-language prompt)
- `status`: `queued | in_progress | completed | error`
- `summary`: optional human-readable summary
- `workspace_path`: filesystem path to project workspace

### Job

- `id` (UUID string)
- `project_id`
- `job_type`: `initial_project | edit`
- `instruction`: natural-language job description
- `status`: `queued | in_progress | completed | error`
- `result_path`: path to `.codex/result.json` in workspace
- `logs_path`: optional path to log file

---

## 3. Execution flow

### 3.1 Create project

1. Client sends `POST /api/v1/projects` with JSON:
   ```json
   { "instruction": "Generate a minimal Python CLI project that prints the first 10 Fibonacci numbers and includes a basic test." }
   ```

2. Backend:
   - Writes a `Project` row with `status=queued`.
   - Creates a workspace directory `WORKSPACE_ROOT/<project_id>`.
   - Creates initial `Job`:
     - `job_type="initial_project"`
     - `instruction` = same as project instruction
     - `status="in_progress"`

3. Backend calls `run_codex_job(db, project, job)`:
   - Writes `.codex/request.json` with:
     - `project_id`, `job_id`, `job_type`, `instruction`
   - If `USE_DUMMY_WORKER=True`:
     - Generates a minimal Python CLI Fibonacci project (README.md, app.py, tests/test_cli.py).
     - Writes `.codex/result.json`.
     - Marks job as `completed`.
   - Else:
     - Calls `docker run` with `CODEX_WORKER_IMAGE` and workspace mounted.
     - Waits for container exit.
     - Reads `.codex/result.json`.
     - Updates job status accordingly.

4. Backend updates project status based on job status and returns `ProjectSummary`.

### 3.2 List and view files

- `GET /api/v1/projects/{project_id}/files`
  - Recursively lists files under workspace.
- `GET /api/v1/projects/{project_id}/files/{path}`
  - Returns file contents.

### 3.3 Add an edit job

- `POST /api/v1/{project_id}/jobs`
  - Body:
    ```json
    {
      "job_type": "edit",
      "instruction": "Append a comment line to app.py describing the change."
    }
    ```
  - Backend:
    - Inserts `Job` with `status="in_progress"`.
    - Calls `run_codex_job`.
    - Worker reads current workspace (including previous files), applies changes, writes `result.json`.

You will extend the worker to actually apply edits via Codex.

---

## 4. Running locally (dummy mode)

### Step 1 – Setup

```bash
cp .env.example .env
docker-compose build
docker-compose up
```

### Step 2 – Test API

- Visit `http://localhost:8000/docs` for Swagger UI.
- Or use curl:

```bash
curl -X POST http://localhost:8000/api/v1/projects   -H "Content-Type: application/json"   -d '{"instruction": "Build me a snake game in the browser."}'
```

### Step 3 – Inspect workspace

After project creation, look under `backend/workspaces/<project_id>`. You should see:

- `README.md`
- `app.py`
- `tests/test_cli.py`
- `.codex/request.json`
- `.codex/result.json`

---

## 5. Wiring in the real Codex worker

You must do three things:

### 5.1 Implement Codex logic in `worker/run_codex_job.py`

Replace the stub with:

1. Read `.codex/request.json`.
2. Use the Codex CLI or SDK to:
   - Inspect the workspace directory.
   - Turn `instruction` into an internal plan.
   - Apply changes (create/edit/delete files).
3. Serialize a structured result to `.codex/result.json`:
   - `status`
   - `summary`
   - `created_files`
   - `modified_files`
   - `errors`
   - `logs` (optional)

Keep the shape aligned with what backend expects.

### 5.2 Build the worker image and push (if needed)

```bash
cd worker
docker build -t codex-worker:latest .
```

Update `.env`:

```env
USE_DUMMY_WORKER=False
CODEX_WORKER_IMAGE=codex-worker:latest
```

### 5.3 Ensure backend can run docker

Backend calls:

```python
cmd = [
    "docker", "run", "--rm",
    "-v", f"{workspace}:/workspace",
    settings.CODEX_WORKER_IMAGE,
]
```

You can replace this with:

- Docker SDK
- Kubernetes Job
- Nomad, etc.

Core requirement: worker sees `/workspace` and `.codex/request.json` and writes `.codex/result.json`.

---

## 6. Extension points

### 6.1 Auth & multi-tenant

- Add a `users` table and `owner_id` on `projects`.
- Add auth middleware (JWT, OAuth, etc.).
- Scope queries by user.

### 6.2 Async jobs / queue

Right now, `run_codex_job` is synchronous.

Options:

- Use FastAPI `BackgroundTasks`.
- Add a Redis/ RabbitMQ queue and a separate worker process.
- Track job progress via polling endpoints.

### 6.3 Deployment / preview URLs

Once you have a working workspace:

- For static sites:
  - Serve `index.html` via static hosting or a dev server.
- For Node/Python backends:
  - Start a sandboxed container per project with forwarded port.
- Store and return `preview_url` in result JSON and DB.

### 6.4 Logging

- Stream worker logs:
  - Capture `stdout/stderr` from `docker run`.
  - Write to a log file in workspace.
  - Expose `GET /projects/{id}/jobs/{job_id}/logs`.

### 6.5 Error Responses

Global error handling is centralized and standardized. Handlers are registered in [create_app()](backend/main.py:8) and implemented in [backend/app/core/errors.py](backend/app/core/errors.py:1). The canonical schema is [ErrorResponse](backend/app/schemas/errors.py:1).

Schema
- error: machine-readable string (e.g., "bad_request", "not_found", "validation_error", "internal_error")
- message: short human-readable summary
- code: integer HTTP status code
- detail: optional info (validation errors list or original message)
- correlation_id: optional; reserved for future middleware (omitted/null for now)

Mappings
- 400 (HTTPException) → error="bad_request", message="Bad request", detail=original exc.detail
- 404 (HTTPException) → error="not_found", message="Not found", detail=original exc.detail
- 422 (RequestValidationError) → error="validation_error", message="Validation failed", detail=list of {loc,msg,type}
- 5xx (unhandled Exception) → error="internal_error", message="Internal server error", no detail

Logging
- 4xx responses are logged at warning with method and path.
- 5xx responses are logged at error with stack traces (exc_info=True).
- Logging is configured in [backend/app/core/logging.py](backend/app/core/logging.py:1).

Examples
- 400 Bad Request:
  ```json
  { "error": "bad_request", "message": "Bad request", "code": 400, "detail": "Invalid path" }
  ```
- 404 Not Found:
  ```json
  { "error": "not_found", "message": "Not found", "code": 404, "detail": "Project not found" }
  ```
- 422 Validation Error:
  ```json
  {
    "error": "validation_error",
    "message": "Validation failed",
    "code": 422,
    "detail": [{ "loc": ["body", "instruction"], "msg": "Field required", "type": "missing" }]
  }
  ```
- 500 Internal Server Error:
  ```json
  { "error": "internal_error", "message": "Internal server error", "code": 500 }
  ```

Notes
- Status codes and success payloads remain unchanged.
- The handlers ensure application/json for error responses and exclude null fields.

---
## 6.6 Request Validation

Incoming request bodies are strictly validated by Pydantic (v2). Invalid inputs are surfaced as standardized 422 responses via [request_validation_error_handler()](backend/app/core/errors.py:50), conforming to [ErrorResponse](backend/app/schemas/errors.py:25).

Schemas and constraints
- [ProjectCreate](backend/app/schemas/projects.py:7)
  - instruction: trimmed string
    - min_length=5, max_length=2000 via Field constraints
    - after trimming, must not be empty. Validator raises: "instruction must not be empty".
- [JobCreate](backend/app/schemas/jobs.py:13)
  - job_type: enum [JobType](backend/app/schemas/jobs.py:8) with values "initial_project" | "edit"
  - instruction: trimmed string
    - min_length=1, max_length=2000
    - after trimming, must not be empty (same validator and message)

Implementation notes (Pydantic v2)
- Trimming via @field_validator(..., mode="before") on the instruction field ensures we validate post-trim length and forbid whitespace-only payloads.
- Length constraints are declared in-line using Annotated[str, Field(...)] for clean OpenAPI generation.
- job_type uses a string-backed Enum to emit neat OpenAPI enum values and JSON strings at runtime.

OpenAPI examples
- Both request models define examples via model_config.json_schema_extra:
  - [ProjectCreate](backend/app/schemas/projects.py:21)
  - [JobCreate](backend/app/schemas/jobs.py:28)

Developer testing tips
- Unit tests assert both failure and success paths:
  - 422 for short/too-long/empty instruction and invalid job_type
  - 200 for valid payloads
- Example quick checks (pytest -k):
  - pytest backend/tests/test_validation.py::test_project_instruction_too_short -q
  - pytest backend/tests/test_validation.py::test_valid_project_and_job -q

Error shape
- See mappings in [http_exception_handler()](backend/app/core/errors.py:70) and [request_validation_error_handler()](backend/app/core/errors.py:50).
- 422 payload example:
  ```json
  {
    "error": "validation_error",
    "message": "Validation failed",
    "code": 422,
    "detail": [
      { "loc": ["body", "instruction"], "msg": "String should have at least 5 characters", "type": "string_too_short" }
    ]
  }
  ```

## 7. Step-by-step for your developer

1. **Clone repo and set up environment**
   - Copy `.env.example` → `.env`.
   - Adjust `WORKSPACE_ROOT` if needed.

2. **Run in dummy mode**
   - `docker-compose build`
   - `docker-compose up`
   - Use Swagger UI to create a project and inspect generated files.

3. **Integrate real Codex**
   - Edit `worker/run_codex_job.py`:
     - Read `.codex/request.json`.
     - Call Codex.
     - Write `.codex/result.json`.
   - Add dependencies to `worker/Dockerfile`.
   - Rebuild worker image.

4. **Switch off dummy worker**
   - Set `USE_DUMMY_WORKER=False` in `.env`.
   - Restart backend.

5. **Harden the system**
   - Add auth.
   - Add rate limits.
   - Move DB to Postgres.
   - Replace synchronous job execution with queue.

6. **Build frontend**
   - Use:
     - `POST /api/v1/projects` to create project.
     - `GET /api/v1/projects/{id}` to show status.
     - `GET /api/v1/projects/{id}/files` + `/files/{path}` to show code tree + editor.
     - `POST /api/v1/{id}/jobs` for edits.

---
## 8. Database migrations (Alembic)

The backend now uses Alembic to manage schema changes. Tables are no longer created implicitly at runtime.

Key files
- Alembic config: backend/alembic.ini
- Alembic env: backend/alembic/env.py (wired to target_metadata = Base.metadata from app DB models)
- Migrations: backend/alembic/versions/
- Models: backend/app/db/models.py

Install dependencies
```bash
pip install -r backend/requirements.txt
```

Initialize or upgrade your DB
```bash
cd backend
alembic upgrade head
```

Existing databases with identical schema
If you already have a DB that matches the current models but isn’t stamped:
```bash
cd backend
alembic stamp head
```

Create a new migration after editing models
1) Edit backend/app/db/models.py
2) Generate a revision and apply it:
```bash
cd backend
alembic revision --autogenerate -m "describe change"
alembic upgrade head
```

Runtime behavior (Docker)
- The backend container applies migrations on startup via backend/docker-entrypoint.sh:
  - Tries alembic upgrade head
  - If upgrade fails due to an existing identical schema without stamps, falls back to alembic stamp head
- Uvicorn starts only after migrations are handled.

Notes
- DATABASE_URL is read from the environment by Alembic; if unset, it falls back to the default in backend/app/core/config.py.
- Implicit DDL has been removed: Base.metadata.create_all calls are no longer used in API paths.
- The baseline migration includes the projects and jobs tables matching the current models.

Verification test for updated_at
- A pytest validates automatic updated_at changes on UPDATE for both Project and Job:
```bash
pytest backend/tests/test_updated_at.py -q
```
- The models implement default=datetime.utcnow and onupdate=datetime.utcnow for updated_at, plus defensive SQLAlchemy before_update listeners to ensure timestamp bumps during flush/commit.

Troubleshooting
- If Alembic cannot connect, verify DATABASE_URL in your .env and that backend/app/core/config.py matches expected defaults.
- For SQLite, paths are relative to the working directory. The default is sqlite:///./codex.db (repo root).

---
## Security: File Access

The backend strictly sandboxes all file operations to each project's workspace directory to prevent path traversal and symlink escapes.

Policy
- Allowed
  - Relative paths that resolve to a location under the project's workspace directory.
  - Hidden files/folders (including .codex) as long as they remain within the workspace.
- Blocked (HTTP 400)
  - Absolute paths (e.g., /etc/passwd)
  - Windows drive or UNC-style paths (e.g., C:\Windows\..., \\server\share)
  - Traversal/escape attempts (../, ../../etc/passwd)
  - URL-encoded traversal or absolute paths (%2e%2e/, %2Fetc%2Fpasswd)
  - Symlinks that resolve to targets outside the workspace
- Safe but missing (HTTP 404)
  - Paths that are valid and inside the workspace but where the file does not exist

Implementation
- Centralized resolver and hardened operations:
  - [backend/app/services/workspaces.py](backend/app/services/workspaces.py)
  - [backend/app/api/routes/files.py](backend/app/api/routes/files.py)
- Key behavior:
  - Joins user-supplied path with the workspace root.
  - Rejects absolute/drive/UNC paths early.
  - Uses Path.resolve(strict=False) to normalize and then verifies containment via relative_to(workspace_root).
  - For reads, additionally resolves with strict=True to detect symlink escapes at the final target before opening.

Developer guidance
- Do not build paths via os.path.join or direct Path concatenation in routes or services without passing through the safe resolver.
- Listing uses os.walk with followlinks=False; directory symlinks are not traversed. Files whose realpath escapes the workspace are skipped.
- The .codex folder is accessible to allow worker I/O (request/result artifacts).

Examples
- Valid read
  - curl -sS "$BASE/api/v1/$PID/files/index.html" → 200 with contents
- Invalid traversal
  - curl -sS "$BASE/api/v1/$PID/files/../secrets.txt" → 400 Invalid path
  - curl -sS "$BASE/api/v1/$PID/files/%2e%2e/secrets.txt" → 400 Invalid path
- Invalid absolute
  - curl -sS "$BASE/api/v1/$PID/files/%2Fetc%2Fpasswd" → 400 Invalid path
- Nonexistent (safe)
  - curl -sS "$BASE/api/v1/$PID/files/does_not_exist.txt" → 404 File not found

Tests
- Unit and API tests cover traversal, absolute, URL-encoded traversal, symlink escapes, and valid access:
  - [backend/tests/test_file_security.py](backend/tests/test_file_security.py)

---
## CORS Configuration

The backend now uses environment-driven CORS configuration with safe defaults for local development. Settings are defined in [Settings](backend/app/core/config.py:5) and applied in [create_app()](backend/main.py:15) via Starlette's CORSMiddleware.

Environment variables
- ALLOW_ORIGINS: Comma-separated list of allowed origins.
- ALLOW_METHODS: Comma-separated list of allowed HTTP methods.
- ALLOW_HEADERS: Comma-separated list of allowed request headers.
- ALLOW_CREDENTIALS: Boolean toggle for credentialed requests (cookies/Authorization).

Defaults (dev-friendly)
- ALLOW_ORIGINS=http://localhost:3000,http://127.0.0.1:3000
- ALLOW_METHODS=GET,POST,PUT,DELETE,OPTIONS
- ALLOW_HEADERS=Authorization,Content-Type
- ALLOW_CREDENTIALS=False

Examples
- Multiple origins
  ```env
  ALLOW_ORIGINS=https://app.example.com,https://admin.example.com
  ```
- Methods and headers
  ```env
  ALLOW_METHODS=GET,POST
  ALLOW_HEADERS=Authorization,Content-Type,X-Requested-With
  ```
- Credentials
  ```env
  ALLOW_CREDENTIALS=True
  # Note: With credentials enabled, browsers require explicit origins; "*" is not allowed.
  ```

Parsing behavior
- List fields accept comma-separated strings and are trimmed.
- Empty strings resolve to empty lists.
- JSON-style lists also work (Pydantic will pass through).
- See field validators in [Settings](backend/app/core/config.py:5).

Security notes
- Do not use "*" in production. Keep origins, methods, and headers minimal.
- If ALLOW_CREDENTIALS=True, you must specify explicit origins; wildcard is disallowed by browsers.
- CORS is a browser protection and does not replace authentication and authorization.
- No secrets are involved; .env.live is not used for this feature.

Testing
- Automated tests validate allowed/blocked origins and preflight OPTIONS behavior:
  - See [backend/tests/test_cors.py](backend/tests/test_cors.py:1).
- Run the suite:
  ```bash
  pytest -q
  ```

Implementation references
- Settings and parsing: [Settings](backend/app/core/config.py:5)
- Middleware wiring: [create_app()](backend/main.py:15)

---
## Live Validation Suite (real worker)

This section describes how to run the staged, gated live end-to-end validation suite that executes the real worker container (USE_DUMMY_WORKER=False), captures evidence artifacts, and enforces presence-only secret handling.

Authoritative plan
- Plan document: [docs/plans/live-validation-suite-2025-11-14T17-14Z.md](docs/plans/live-validation-suite-2025-11-14T17-14Z.md)
- Orchestrator script (L01–L08): [tools/http/live_suite/run_all.sh](tools/http/live_suite/run_all.sh:1)
- Base live runner (L01–L06): [tools/http/live.sh](tools/http/live.sh:1)
- Backend runner function: [run_codex_job()](backend/app/services/codex_runner.py:95)
- Live worker entrypoint: [main()](worker/run_codex_job.py:138)
- Additional overview: [README.md](README.md:1)
- Evidence guidance: [docs/evidence/README.md](docs/evidence/README.md:1)

Prerequisites (do not print secrets)
1) Environment
   - .env:
     - USE_DUMMY_WORKER=False
     - CODEX_WORKER_IMAGE=codex-worker:latest (or your image)
   - .env.live: OPENAI_API_KEY, OPENAI_ORG_ID, OPENAI_PROJECT (never committed)
   - Confirm .gitignore excludes .env and .env.live.
2) Docker access from backend
   - Backend container must include docker CLI and mount /var/run/docker.sock.
   - The runner [run_codex_job()](backend/app/services/codex_runner.py:95) invokes:
     - docker run --rm -v &lt;workspace&gt;:/workspace -e OPENAI_API_KEY -e OPENAI_ORG_ID -e OPENAI_PROJECT ${CODEX_WORKER_IMAGE}
   - Worker image default CMD runs [main()](worker/run_codex_job.py:138) via Dockerfile CMD.
3) Build images and run backend
```bash
# From repo root
docker build -t codex-worker:latest -f worker/Dockerfile .

docker-compose build
docker-compose up
# Swagger: http://localhost:8000/docs
```

Running the suite (L01–L08, gated)
- The suite creates a UTC ISO-8601 timestamped evidence root and writes per-scenario artifacts there.
```bash
# From repo root
BASE_URL=http://localhost:8000 OUTROOT=docs/evidence bash tools/http/live_suite/run_all.sh
```
- Evidence root example: docs/evidence/2025-11-14T17:20:00Z/live/
- Per-scenario directories:
  - L01–L08 with response.json, project_id.txt, result.json, result_excerpt.txt, files.json, app.json as applicable
- Suite-level summary:
  - docs/evidence/&lt;timestamp&gt;/live/summary.txt

Scenario overview (expected behavior)
- L01 Env presence: result.json logs show OPENAI_*=(present|absent); no values
- L02 Simple scaffold: .codex artifacts present; initial files (README.md, app.py, tests/test_cli.py) typically created by [generate_initial()](worker/run_codex_job.py:34)
- L03 File list: includes .codex/{request.json,result.json}
- L04 Representative file: GET app.py → non-empty contents
- L05 Edit (feature): [apply_edit()](worker/run_codex_job.py:108) appends a comment and marks app.py as modified
- L06 Edit (refactor): instructs a small refactor; expect modified_files includes app.py (or structured limitation)
- L07 Negative/error: "force_error" triggers status="error" and errors includes "forced_error"
- L08 Long-running: extended polling up to ~10 minutes; outcome is success or structured error without crashes

Evidence structure and redaction
- See [docs/evidence/README.md](docs/evidence/README.md:1) for exact filenames.
- Presence-only secret policy:
  - Worker logs must include only present/absent for OPENAI_*; never store raw secret values
  - If any value appears, redact with [REDACTED] before saving artifacts

Debugging and inspection tips
- Backend logs (container name may vary):
```bash
docker-compose logs -f backend
```
- Expect to see docker run issued by [run_codex_job()](backend/app/services/codex_runner.py:95).
- Workspace on host:
```bash
ls -la ./backend/workspaces/<project_id>/
cat ./backend/workspaces/<project_id>/.codex/result.json
```
- API checks:
```bash
# Create (trailing slash)
curl -sS -X POST "$BASE/api/v1/projects/" -H "Content-Type: application/json" \
  -d '{"instruction":"Generate a minimal Python CLI project that prints the first 10 Fibonacci numbers and includes a basic test."}' | jq .

# List
curl -sS "$BASE/api/v1/$PID/files" | jq .

# Representative file
curl -sS "$BASE/api/v1/$PID/files/app.py" | jq .

# Edit
curl -sS -X POST "$BASE/api/v1/$PID/jobs" \
  -H "Content-Type: application/json" \
  -d '{"job_type":"edit","instruction":"Append a comment line to app.py describing the change."}' | jq .
```

Gating and failure handling
- The orchestrator exits non-zero on unmet expectations and stops subsequent scenarios.
- On FAIL:
  - Preserve evidence directory as-is
  - Add notes.txt capturing observed behavior and hypotheses
  - Remediate and re-run from the beginning or targeted scenario as needed

Rollback to mocked mode (post-run)
```bash
# .env
#   USE_DUMMY_WORKER=True
docker-compose build
docker-compose up

# Optional: re-run mocked smoke tests (M01–M04)
```

Appendix: Worker details
- The Dockerfile sets a default CMD:
  - See the worker image spec: worker/Dockerfile (CMD python /app/run_codex_job.py)
- The minimal live worker behavior:
  - Initial generation: [generate_initial()](worker/run_codex_job.py:34)
  - Edits: [apply_edit()](worker/run_codex_job.py:108)
  - Controlled failure: "force_error" handled in [main()](worker/run_codex_job.py:138)
