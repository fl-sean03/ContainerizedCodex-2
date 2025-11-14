# Home Server Quickstart

This guide is a step-by-step for bringing the Codex Workspace Orchestrator up on a home server with Docker and Caddy. It assumes you will receive this repository URL and follow the exact commands below.

References:
- Repo root README: [README.md](README.md)
- Compose file: [docker-compose.yml](docker-compose.yml)
- Local dev env example: [.env.example](.env.example)
- Live env example (no secrets): [.env.live.example](.env.live.example)
- Backend settings (CORS, worker toggles): [Settings](backend/app/core/config.py:16)
- Live validation orchestrator (optional): [run_all.sh](tools/http/live_suite/run_all.sh:1)

---

## 0) Prerequisites

- Git
- Docker Engine and Docker Compose plugin
- Caddy installed (systemd service recommended)
- Ports:
  - Backend container exposes 8000 by default (mapped in [docker-compose.yml](docker-compose.yml))
  - Caddy will listen on :80 (and/or :443 if/when you add TLS)

---

## 1) Fetch the repository

Replace the URL with your repo if different.

```bash
git clone https://github.com/fl-sean03/ContainerizedCodex-2.git
cd ContainerizedCodex-2
git checkout main
```

---

## 2) Start in dummy mode (no secrets needed)

Dummy mode runs a local stub worker. It generates a minimal Python CLI project and is safe to run without any external API keys.

```bash
# Create local env from example
cp .env.example .env

# Build and start services
docker-compose build
docker-compose up -d

# Verify containers
docker ps
```

Default endpoints:
- Backend: http://localhost:8000
- Swagger UI: http://localhost:8000/docs

If port 8000 is busy, edit the ports mapping in [docker-compose.yml](docker-compose.yml) (e.g., change to "8001:8000") and adjust your URLs accordingly.

---

## 3) Quick API smoke test

```bash
BASE=http://localhost:8000
curl -sS -X POST "$BASE/api/v1/projects/" \
  -H "Content-Type: application/json" \
  -d '{"instruction":"Generate a minimal Python CLI that prints the first 10 Fibonacci numbers and includes a basic test."}' | jq .
```

Expected: a JSON response with status "completed" and a project id. You can list files with:

```bash
curl -sS "$BASE/api/v1/projects/<project_id>/files" | jq .
```

Workspaces are stored on the host under ./backend/workspaces and are bind-mounted into the backend container.

---

## 4) Caddy reverse proxy (no domain yet)

If Caddy runs on the same host as Docker, a minimal Caddyfile:

```
:80 {
  reverse_proxy 127.0.0.1:8000
}
```

If Caddy runs on a different node, point to the Docker host IP instead of 127.0.0.1.

Reload Caddy:
```bash
sudo systemctl reload caddy
```

CORS notes:
- Allowed origins are driven by env and default to localhost in [.env.example](.env.example). If a browser frontend will connect via Caddy on a different origin, set ALLOW_ORIGINS accordingly in [.env](.env.example).

---

## 5) Optional: switch to live mode later (uses your API keys)

Live mode runs the worker container with real API access. Do NOT commit secrets.

```bash
# 1) Create and fill the live env file locally (never commit)
cp .env.live.example .env.live
# Edit .env.live and set:
#   OPENAI_API_KEY=...
#   OPENAI_ORG_ID=...
#   OPENAI_PROJECT=...

# 2) Toggle off the dummy worker in .env
sed -i "s/^USE_DUMMY_WORKER=.*/USE_DUMMY_WORKER=False/" .env

# 3) Build and restart
docker-compose build
docker-compose up -d
```

Optional worker build:
- The default compose expects a worker image named codex-worker:latest. If you customize it, build from the included Dockerfile:
```bash
docker build -t codex-worker:latest -f worker/Dockerfile .
```

---

## 6) Optional: run the live validation suite

Ensure the backend is running in live mode before executing.

```bash
BASE_URL=http://localhost:8000 OUTROOT=docs/evidence bash tools/http/live_suite/run_all.sh
```

Evidence is written under docs/evidence/<ISO8601Z>/live/. Secrets are never printed; logs show presence-only lines by design (OPENAI_* present/absent). See [Evidence Guide](docs/evidence/README.md) if needed.

---

## 7) Troubleshooting

- Port conflict on 8000
  - Edit ports in [docker-compose.yml](docker-compose.yml) from "8000:8000" to "8001:8000" and use http://localhost:8001.
- Backend container not ready
  - Check logs: `docker logs -f codex-backend`
- Permission issues writing workspaces
  - Workspaces are bind-mounted at ./backend/workspaces; ensure your user can write to this directory on the host.
- 307 redirect on POST /projects
  - Use the trailing-slash endpoint: /api/v1/projects/

---

## 8) Roll back to dummy mode

```bash
sed -i "s/^USE_DUMMY_WORKER=.*/USE_DUMMY_WORKER=True/" .env
docker-compose build
docker-compose up -d
```

---

## Appendix: environment keys (backend)

See [Settings](backend/app/core/config.py:16) for all env defaults. Key items you may change in [.env](.env.example):
- USE_DUMMY_WORKER=True|False
- CODEX_WORKER_IMAGE=codex-worker:latest
- DATABASE_URL=sqlite:///./codex.db
- WORKSPACE_ROOT=./workspaces
- ALLOW_ORIGINS=http://localhost:3000,http://127.0.0.1:3000
- ALLOW_METHODS=GET,POST,PUT,DELETE,OPTIONS
- ALLOW_HEADERS=Authorization,Content-Type
- ALLOW_CREDENTIALS=False

Live-only secrets go into [.env.live](.env.live.example) created from [.env.live.example](.env.live.example). Never commit this file; it is gitignored by [".gitignore"]( .gitignore).

---

This document lives at: docs/HOME_SERVER_QUICKSTART.md