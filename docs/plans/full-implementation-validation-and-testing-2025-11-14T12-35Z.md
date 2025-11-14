# Full Implementation Validation and Testing Plan — 2025-11-14T12:35Z

1. Overview
- Goal: Validate the Codex Workspace Orchestrator end-to-end in both mocked and live modes per the developer guide, ensuring reliability, security, and documented procedures.
- Outputs:
  - Verified mocked mode (USE_DUMMY_WORKER=True) behavior end-to-end.
  - Verified live mode integration with real worker container using API keys from .env.live without exposing secrets.
  - Evidence artifacts (responses, file listings, result.json excerpts), and updated documentation.
  - Clear rollback to mocked mode.

2. Scope
- In-scope:
  - Mocked flow: local Docker Compose, API smoke tests, workspace artifacts.
  - Live flow: real worker container invocation with env passthrough (OPENAI_API_KEY, OPENAI_ORG_ID, OPENAI_PROJECT), evidence capture, and safe rollback.
  - Security hygiene: never printing secrets, confirming .env/.env.live are ignored by VCS.
- Out-of-scope:
  - Non-essential features or refactors beyond what’s required to validate mocked/live behavior.

3. Assumptions and Constraints
- Secrets file [.env.live](.env.live) exists at workspace root and is NOT committed (ensure [".gitignore"](.gitignore)).
- Default runtime is Docker Compose using [docker-compose.yml](docker-compose.yml).
- Backend API base URL: http://localhost:8000 with Swagger at /docs.
- Live worker image is defined via CODEX_WORKER_IMAGE in [.env](.env) or [.env.live](.env.live), used by [run_codex_job()](backend/app/services/codex_runner.py:59).
- We will not log secret values; only presence checks will be logged.

4. References (context bundle)
- Compose and docs: [docker-compose.yml](docker-compose.yml), [README.md](README.md), [DEV_GUIDE.md](DEV_GUIDE.md)
- Backend app: [backend/main.py](backend/main.py), [backend/app/core/config.py](backend/app/core/config.py:1)
- API routes: [projects](backend/app/api/routes/projects.py:20), [files](backend/app/api/routes/files.py:12), [jobs](backend/app/api/routes/jobs.py:12)
- Runner: [codex_runner.run_codex_job()](backend/app/services/codex_runner.py:59), [dummy_worker_generate_snake_game()](backend/app/services/codex_runner.py:29)
- Security: [workspaces service](backend/app/services/workspaces.py)
- DB/migrations: [backend/app/db/models.py](backend/app/db/models.py:1), [backend/alembic](backend/alembic/env.py)

5. Environments
- Mocked (default)
  - USE_DUMMY_WORKER=True
  - Worker invocation short-circuits to [dummy_worker_generate_snake_game()](backend/app/services/codex_runner.py:29)
  - Verifies basic orchestration and workspace artifacts.
- Live
  - USE_DUMMY_WORKER=False
  - Docker run worker: [run_codex_job()](backend/app/services/codex_runner.py:59) launches CODEX_WORKER_IMAGE with:
    - Volume: -v <workspace>:/workspace
    - Env passthrough: -e OPENAI_API_KEY -e OPENAI_ORG_ID -e OPENAI_PROJECT
  - Produces .codex/result.json from a real agent flow (implementation-dependent).

6. Pre-flight Checklist
- [ ] .env present and configured for mocked flow (USE_DUMMY_WORKER=True).
- [ ] .env.live present with valid keys; not committed; .gitignore includes .env and .env.live.
- [ ] Docker images build cleanly; docker-compose up exposes /docs.
- [ ] SQLite (default) ready; Alembic baseline applied automatically on backend startup.

7. Test Matrix (summary)
- Mocked Mode
  - Create Project: POST /api/v1/projects → status completed; workspace with README.md, app.py, tests/test_cli.py; .codex/result.json status=success.
  - List Files: GET /api/v1/{project_id}/files → contains 5 expected files.
  - Get File: GET /api/v1/{project_id}/files/app.py → non-empty contents.
  - Edit Job: POST /api/v1/{project_id}/jobs (edit) → status completed (dummy behavior).
  - Security: traversal attempts → 400; safe-nonexistent → 404.
- Live Mode
  - Env Passthrough: worker sees OPENAI_API_KEY/ORG_ID/PROJECT present (logged as presence only).
  - Create Project (initial_project) executes docker-run path; writes .codex/result.json and expected artifacts (implementation dependent).
  - Edit Job writes updated artifacts according to instruction or returns a structured error.
  - Rollback to mocked mode after validation.

8. Evidence to Collect
- API JSON responses for each endpoint in both modes (redact IDs only if needed; never include secrets).
- Directory listing under backend/workspaces/{project_id}/ and sizes.
- Excerpts of .codex/result.json (status, summary, created_files/modified_files).
- Backend logs: successful request lines and worker invocation info (no secrets).

9. Execution Steps — Mocked
1) Ensure mocked env:
   - Confirm [.env](.env) contains USE_DUMMY_WORKER=True, WORKSPACE_ROOT=./workspaces, DATABASE_URL=sqlite:///./codex.db.
2) Compose build and up:
   - docker-compose build
   - docker-compose up
3) Verify readiness:
   - Open http://localhost:8000/docs
4) API smoke tests:
   - Create Project: POST /api/v1/projects with {"instruction":"Generate a minimal Python CLI project that prints the first 10 Fibonacci numbers and includes a basic test."}
   - List Files: GET /api/v1/{project_id}/files
   - Get app.py: GET /api/v1/{project_id}/files/app.py
   - Edit Job: POST /api/v1/{project_id}/jobs with {"job_type":"edit","instruction":"Append a comment line to app.py describing the change."}
5) Validate workspace:
   - backend/workspaces/{project_id}/ contains .codex/{request.json,result.json}, README.md, app.py, tests/test_cli.py
6) Security checks:
   - Traversal/absolute/encoded paths → expect 400; safe-missing → 404
7) Capture evidence (as described above).

10. Execution Steps — Live
1) Prepare live env (do not print secrets):
   - Source .env.live locally (or merge values into an ephemeral environment).
   - Set in [.env](.env) or compose overrides:
     - USE_DUMMY_WORKER=False
     - CODEX_WORKER_IMAGE=codex-worker:latest (or provided image)
2) Ensure worker env passthrough in [run_codex_job()](backend/app/services/codex_runner.py:59):
   - docker run ... -e OPENAI_API_KEY -e OPENAI_ORG_ID -e OPENAI_PROJECT ...
   - Worker must not log secret values; presence-only.
3) Compose rebuild and up:
   - docker-compose build
   - docker-compose up
4) Live API tests:
   - Create Project: POST /api/v1/projects with {"instruction":"Generate a minimal Python CLI project that prints the first 10 Fibonacci numbers and includes a basic test."}
     - Expect docker-run execution, .codex/result.json with status and summary.
   - List Files and Get File as in mocked flow; validate contents returned by live agent.
   - Optional: Edit Job with a small change to confirm edit path.
5) Evidence capture (no secrets) and compare to mocked behavior.
6) Rollback:
   - Restore [.env](.env) to USE_DUMMY_WORKER=True and restart compose.

11. Acceptance Criteria
- Mocked
  - All four core endpoints return 200 with expected data/behavior.
  - Workspace contains expected files; .codex/result.json.status=success.
  - Path traversal protections enforced (400) and safe-missing returns 404.
- Live
  - Worker received envs (presence confirmed via logs/result.json logs field).
  - .codex/result.json exists with a coherent summary/status; artifacts generated or a structured error is returned.
  - System stability preserved; no secrets printed.
- Documentation
  - README/DEV_GUIDE updated to include live testing guidance, rollback steps, and security guidance about secrets.

12. Risks and Mitigations
- Secret leakage:
  - Mitigation: never print values; add checks to ensure logs only state presence. Confirm [.gitignore](.gitignore) ignores .env and .env.live.
- Worker failures/timeouts:
  - Mitigation: capture error summary in result.json; document retry/backoff path in roadmap.
- Port/volume conflicts:
  - Mitigation: switch port to 8001 if needed; ensure volumes are writable by container user.

13. Roles and Ownership (per Orchestrator lifecycle)
- Architect: validates plan and produces the to-do list and acceptance criteria.
- Code: executes the plan exactly, collects evidence, and updates documentation.
- Orchestrator: supervises sequencing and verifies exit criteria are met before progressing.

14. To-Do List Items (tie-ins)
- Completed: mocked validation steps per [README.md](README.md).
- Pending:
  - Define mocked vs live test matrix and acceptance criteria in issues/docs.
  - Live enablement work: configure USE_DUMMY_WORKER=False, CODEX_WORKER_IMAGE, env passthrough (-e OPENAI_*).
  - Worker instrumentation (presence logs only) and result.json logs indicator.
  - Live E2E run; revert back to mocked.
  - Document live testing guidance and rollback.

15. Evidence Storage
- Store non-sensitive evidence under docs/evidence/ with per-run timestamps:
  - docs/evidence/2025-11-14T12-35Z/mocked/
  - docs/evidence/2025-11-14T12-35Z/live/
- Include: API responses (json), workspace file lists (txt), result.json excerpts (txt).

16. Rollback Procedure
- Reset [.env](.env) to USE_DUMMY_WORKER=True and restart docker-compose.
- Remove any temporary live-only env overrides.
- Confirm via /docs and smoke tests that mocked mode is operating.

17. Next Steps (immediate)
- Switch to Orchestrator to coordinate:
  - Define/record the detailed mocked vs live test case list and expected outputs.
  - Execute live enablement and E2E with .env.live keys (without printing them).
  - Capture and store evidence; update docs accordingly.