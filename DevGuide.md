Here’s the full developer guide starting from “blank folder + zip file”. Hand this directly to whoever is building it.

---

# Codex Workspace Orchestrator – Developer Guide

This guide assumes:

* You start in an **empty directory** with a single file:
  `codex-platform-backend.zip`
* You know basic Docker, Python, and HTTP, but you have **no prior context** about this project.

This document + the zip is everything you need.

---

## 1. Goal: What this project does

This backend is a skeleton for a **natural-language → code workspace** system.

High-level behavior:

* Client sends a prompt like:
  `"Build me a snake game in the browser."`
* Backend:

  * Creates a **project**.
  * Creates a **workspace directory** for that project.
  * Creates a **job** that describes the task.
  * Invokes a **worker** (dummy for now, Codex later) that:

    * Reads the job.
    * Writes code files into the workspace.
    * Writes a `result.json` describing what it did.
* Client can then:

  * List all files in the project.
  * Fetch the contents of any file.
  * Submit follow-up **edit jobs** that modify the workspace.

Right now, the worker is a **stub** that drops in a dummy “snake game” template. The interface is ready for you to plug in a real Codex-based agent.

---

## 2. Unpacking and file layout

### 2.1 Unzip the archive

From your blank directory:

```bash
unzip codex-platform-backend.zip -d codex-platform
cd codex-platform
```

You should now see:

```text
codex-platform/
  backend/
    app/
      api/
        deps.py
        routes/
          __init__.py
          projects.py
          files.py
          jobs.py
      core/
        config.py
        logging.py
      db/
        base.py
        models.py
        session.py
      schemas/
        __init__.py
        projects.py
        jobs.py
        files.py
      services/
        workspaces.py
        codex_runner.py
      __init__.py
      api/__init__.py
      core/__init__.py
      db/__init__.py
      services/__init__.py
    main.py
    requirements.txt
    Dockerfile
  worker/
    Dockerfile
    run_codex_job.py
    dummy_snake_template/
      index.html
      style.css
      main.js
  docker-compose.yml
  .env.example
  README.md
  DEV_GUIDE.md         # You can ignore this now; this doc is the updated guide.
  .gitignore
```

If that’s not roughly what you see, you unzipped into the wrong place.

---

## 3. Core architecture (mental model)

Three main pieces:

1. **Backend (FastAPI)**

   * HTTP API under `/api/v1`.
   * Manages:

     * `Project` objects
     * `Job` objects (initial generation + edits)
     * Workspace directories on disk
   * Orchestrates worker execution.

2. **Workspace storage (filesystem)**

   * Root: configured by `WORKSPACE_ROOT` (default `./workspaces` inside backend).
   * Each project gets a folder:

     * `<WORKSPACE_ROOT>/<project_id>/`
   * Inside each workspace:

     * Real code files (e.g., `index.html`, `main.js`)
     * `.codex/request.json` – the job request.
     * `.codex/result.json` – the worker’s structured result.

3. **Worker container**

   * Runs in Docker with `/workspace` volume.
   * Reads `.codex/request.json`.
   * Writes files + `.codex/result.json`.
   * Current implementation is a stub; you’ll replace logic with Codex integration later.

---

## 4. Running the system (recommended: Docker Compose)

### 4.1 Set up environment file

In `codex-platform/`:

```bash
cp .env.example .env
```

`.env` content:

```env
APP_NAME=Codex Workspace Orchestrator
API_V1_STR=/api/v1

DATABASE_URL=sqlite:///./codex.db
WORKSPACE_ROOT=./workspaces

USE_DUMMY_WORKER=True
CODEX_WORKER_IMAGE=codex-worker:latest
```

Leave this as is for now. `USE_DUMMY_WORKER=True` means the backend will **not** call the worker container; it will instead copy a built-in dummy snake template.

### 4.2 Build and start via Docker Compose

From `codex-platform/`:

```bash
docker-compose build
docker-compose up
```

This will:

* Build the **backend** image from `backend/Dockerfile`.
* Build the **worker** image from `worker/Dockerfile` (even though in dummy mode we don’t actually call it).
* Start:

  * `codex-backend` on port `8000`.
  * `codex-worker` doing nothing (just `sleep infinity` as a placeholder).

When it’s up, you should be able to hit:

* API docs (Swagger): `http://localhost:8000/docs`

---

## 5. Running without Docker (optional, for local dev)

If you want to run the backend directly (no containers):

```bash
cd codex-platform/backend

python -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt

uvicorn main:app --reload --port 8000
```

Important nuance:
In this mode, the dummy worker code expects the dummy template directory to be mounted at runtime under `backend/worker/dummy_snake_template` (due to how the paths are built). In Docker, this is solved via volume mounts.

If you want the dummy worker to work in pure-local mode, create:

```bash
cd codex-platform/backend
mkdir -p worker
cp -r ../worker/dummy_snake_template worker/
```

Then the path inside `codex_runner.py` will resolve correctly.

If you don’t care about dummy worker and you’re going straight to Codex integration, you can ignore this.

---

## 6. Data model (what’s in the DB)

SQLAlchemy models in `backend/app/db/models.py`:

### 6.1 Project

Fields:

* `id: str` – UUID string, primary key.
* `instruction: str` – initial natural-language description from user.
* `status: str` – one of: `"queued" | "in_progress" | "completed" | "error"`.
* `summary: Optional[str]` – optional short summary/status text.
* `workspace_path: str` – absolute or relative path to workspace directory.
* `created_at: datetime`
* `updated_at: datetime`
* `jobs: List[Job]` – relationship to jobs.

### 6.2 Job

Fields:

* `id: str` – UUID string.
* `project_id: str` – foreign key to `projects.id`.
* `job_type: str` – `"initial_project"` or `"edit"`.
* `instruction: str` – natural-language instruction for this job.
* `status: str` – `"queued" | "in_progress" | "completed" | "error"`.
* `result_path: Optional[str]` – path to `.codex/result.json`.
* `logs_path: Optional[str]` – path to logs (not used yet).
* `created_at: datetime`
* `updated_at: datetime`
* `project: Project` – relationship back.

Tables are created automatically when the `projects` route module is loaded, via:

```python
from app.db.session import engine
from app.db.models import Base

Base.metadata.create_all(bind=engine)
```

DB location: `codex.db` in the `backend/` directory (SQLite).

---

## 7. API overview and examples

All routes are under `/api/v1` (from `APP_NAME` / `API_V1_STR` in `config.py`).

### 7.1 Create a project

**Endpoint**

* `POST /api/v1/projects`

**Request body**

```json
{
  "instruction": "Build me a snake game in the browser."
}
```

**Behavior**

* Creates a new `Project` with that instruction.
* Creates workspace directory: `<WORKSPACE_ROOT>/<project_id>`.
* Creates an initial `Job` of type `"initial_project"`.
* Calls `run_codex_job` synchronously:

  * In dummy mode, this copies the dummy snake template into the workspace & writes `.codex/result.json`.
* Updates `Project.status` based on job status.

**Response (example)**

```json
{
  "id": "b5d2d2a3-...-...",
  "instruction": "Build me a snake game in the browser.",
  "status": "completed",
  "summary": "Initial job status: completed",
  "created_at": "2025-11-13T21:00:00Z",
  "updated_at": "2025-11-13T21:00:05Z"
}
```

### 7.2 Get project details

**Endpoint**

* `GET /api/v1/projects/{project_id}`

**Response**

```json
{
  "id": "b5d2d2a3-...-...",
  "instruction": "Build me a snake game in the browser.",
  "status": "completed",
  "summary": "Initial job status: completed",
  "created_at": "...",
  "updated_at": "...",
  "workspace_path": "./workspaces/b5d2d2a3-...-...",
  "jobs": [
    {
      "id": "...",
      "project_id": "...",
      "job_type": "initial_project",
      "instruction": "Build me a snake game in the browser.",
      "status": "completed",
      "created_at": "...",
      "updated_at": "...",
      "result_path": "./workspaces/.../.codex/result.json",
      "logs_path": null
    }
  ]
}
```

### 7.3 List files in a project

**Endpoint**

* `GET /api/v1/{project_id}/files`

**Response example (dummy worker)**

```json
{
  "files": [
    { "path": ".codex/request.json", "size": 200 },
    { "path": ".codex/result.json", "size": 300 },
    { "path": "index.html", "size": 512 },
    { "path": "style.css", "size": 198 },
    { "path": "main.js", "size": 340 }
  ]
}
```

### 7.4 Get a specific file’s contents

**Endpoint**

* `GET /api/v1/{project_id}/files/{file_path}`

Example:

```bash
curl http://localhost:8000/api/v1/b5d2d2a3-.../files/index.html
```

**Response**

```json
{
  "path": "index.html",
  "contents": "<!doctype html>..."
}
```

### 7.5 Add a new job (e.g., edit)

**Endpoint**

* `POST /api/v1/{project_id}/jobs`

**Request body**

```json
{
  "job_type": "edit",
  "instruction": "Add WASD controls and a score display."
}
```

**Behavior**

* Creates a `Job` for that project with type `"edit"`.
* Calls `run_codex_job` again.
* Worker sees current workspace, applies edits, writes new result.

**Response**

```json
{
  "id": "job-uuid",
  "project_id": "b5d2d2a3-...-...",
  "job_type": "edit",
  "instruction": "Add WASD controls and a score display.",
  "status": "completed",
  "created_at": "...",
  "updated_at": "...",
  "result_path": "./workspaces/.../.codex/result.json",
  "logs_path": null
}
```

### 7.6 Get job details

**Endpoint**

* `GET /api/v1/{project_id}/jobs/{job_id}`

**Response**

Same as above `JobDetail` object.

---

## 8. Workspace and worker contract

The key contract between **backend** and **worker** lives in `backend/app/services/codex_runner.py`.

### 8.1 Request format (`.codex/request.json`)

Backend writes this before running the worker:

```json
{
  "project_id": "<project-id>",
  "job_id": "<job-id>",
  "job_type": "initial_project" | "edit",
  "instruction": "Natural language instruction"
}
```

Location:

* `<workspace>/.codex/request.json`

`workspace` = the project’s workspace directory.

### 8.2 Result format (`.codex/result.json`)

Worker must write this after it’s done:

```json
{
  "status": "success" | "error",
  "summary": "Short description of what was done / what failed.",
  "created_files": ["index.html", "style.css", "main.js"],
  "modified_files": [],
  "errors": ["..."],
  "logs": ["..."]
}
```

Location:

* `<workspace>/.codex/result.json`

Backend will:

* Check if `result.json` exists.
* Update `Job.status`:

  * `completed` if result exists and status is success.
  * `error` if missing or if something fails.

---

## 9. Dummy worker vs real Codex worker

### 9.1 Dummy worker (current behavior)

When `USE_DUMMY_WORKER=True`, backend never runs Docker; instead it uses `dummy_worker_generate_snake_game`:

* Source: `backend/app/services/codex_runner.py`.
* It reads the dummy template from
  `/app/worker/dummy_snake_template` in-container, which is mounted from `./worker/dummy_snake_template` via `docker-compose.yml`.
* It copies:

  * `index.html`
  * `style.css`
  * `main.js`
    into the workspace root.
* It writes `.codex/result.json` with a fixed success payload.

This is purely to smoke-test the orchestration and endpoints.

### 9.2 Real worker path

When you flip to `USE_DUMMY_WORKER=False`, `run_codex_job` runs:

```python
cmd = [
    "docker",
    "run",
    "--rm",
    "-v",
    f"{workspace}:/workspace",
    settings.CODEX_WORKER_IMAGE,
]
```

This:

* Starts a *new* worker container.
* Mounts the workspace directory to `/workspace` inside the container.
* Runs the default command in `worker/Dockerfile`:

  ```dockerfile
  CMD ["python", "/app/run_codex_job.py"]
  ```

Inside the container, `run_codex_job.py` must:

1. Read `/workspace/.codex/request.json`.
2. Do the real work (via Codex).
3. Write `/workspace/.codex/result.json`.

Current `worker/run_codex_job.py` is a stub; you will replace its contents to integrate with Codex.

---

## 10. Integrating Codex (what you actually need to implement)

You will modify only **worker side** code for Codex integration.

### 10.1 Update worker Dockerfile

`worker/Dockerfile` currently:

```dockerfile
FROM python:3.11-slim

WORKDIR /app

# Install system deps if needed
RUN apt-get update && apt-get install -y git curl && rm -rf /var/lib/apt/lists/*

# Copy worker code
COPY run_codex_job.py /app/run_codex_job.py

# Workspace is mounted here
VOLUME ["/workspace"]
WORKDIR /workspace

CMD ["python", "/app/run_codex_job.py"]
```

You will:

* Add installs for any SDKs, CLIs, or dependencies needed by Codex:

  * e.g. `pip install openai` or `apt-get install nodejs` if you want to `npm` stuff.
* Possibly add your own Python modules for orchestration.

### 10.2 Replace stub logic in `worker/run_codex_job.py`

Current version:

* Validates that `request.json` exists.
* Writes a trivial success `result.json` with no changes.

You need to:

1. Parse `request.json`:

   ```python
   job = json.loads(request_path.read_text(encoding="utf-8"))
   instruction = job["instruction"]
   job_type = job["job_type"]
   project_id = job["project_id"]
   job_id = job["job_id"]
   ```

2. Use Codex (via CLI or API) to:

   * Inspect current files under `/workspace`.
   * Decide how to implement `instruction`.
   * Create/edit/delete files accordingly.
   * Optionally run commands (`npm install`, tests, etc.).

3. Track what was changed:

   * `created_files`: list of new file paths (relative to `/workspace`).
   * `modified_files`: list of existing files you changed.

4. Write `result.json` with:

   * `status`
   * `summary`
   * `created_files`
   * `modified_files`
   * `errors`
   * `logs` (if you want to log commands/output).

Backend doesn’t care *how* you use Codex — just that you follow the request/result contract.

### 10.3 Turn off dummy worker

After you implement real worker logic:

1. Rebuild worker image:

   ```bash
   cd codex-platform/worker
   docker build -t codex-worker:latest .
   ```

2. In `.env` (root):

   ```env
   USE_DUMMY_WORKER=False
   CODEX_WORKER_IMAGE=codex-worker:latest
   ```

3. Restart:

   ```bash
   cd codex-platform
   docker-compose down
   docker-compose up --build
   ```

Now `run_codex_job` will spin up your Codex worker container for each job.

---

## 11. Extension points (once basic loop works)

After you have Codex plugged in and you can generate/edit projects, there are obvious extensions:

1. **Authentication & multi-tenancy**

   * Add `users` table.
   * Add `owner_id` to `Project`.
   * Filter queries by user; add auth middleware (JWT, OAuth).

2. **Async jobs & progress tracking**

   * Move from synchronous `run_codex_job` to:

     * Background tasks, or
     * Job queue (Redis, RabbitMQ, etc.) + worker.
   * Add `progress` fields or separate `JobEvent` table.

3. **Preview & deploy**

   * For static sites:

     * Serve `/index.html` via a static host or ephemeral dev server.
   * For backend services:

     * Spin up sandbox containers with forwarded ports.
   * Store `preview_url` in `result.json` and DB.

4. **Logging endpoint**

   * Capture `stdout/stderr` from the worker and store as logs.
   * Create `GET /projects/{id}/jobs/{job_id}/logs`.

5. **Validation / test harness**

   * Have worker run tests (if present).
   * Reflect pass/fail in `result.json` and job status.

---

## 12. Checklist for you (developer) to be “done”

Minimum to have a working Codex-backed system:

1. `docker-compose up` works.
2. `POST /api/v1/projects` creates a project.
3. `GET /api/v1/{project_id}/files` returns files.
4. `GET /api/v1/{project_id}/files/index.html` returns code.
5. Flip `USE_DUMMY_WORKER=False`.
6. Implement real logic in `worker/run_codex_job.py`:

   * Reads instruction.
   * Calls Codex.
   * Writes actual generated project.
   * Writes `result.json` with correct schema.
7. Rebuild worker image.
8. Confirm:

   * `POST /api/v1/projects` now triggers Codex, not dummy template.
   * New source code matches what Codex produces.
9. Implement `POST /api/v1/{project_id}/jobs` edit flow:

   * Worker sees existing project and modifies it correctly.

Once that’s done, the backend is a functional NL→workspace orchestration layer over Codex. The frontend can be anything that talks to this API.
