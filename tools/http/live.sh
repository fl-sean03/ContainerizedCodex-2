#!/usr/bin/env bash
# Codex Orchestrator - Live mode test runner
# Runs L01–L06 against a running backend with USE_DUMMY_WORKER=False and a real worker image.
# Requirements: bash, curl, jq
# Usage examples:
#   chmod +x tools/http/live.sh
#   BASE_URL=http://localhost:8000 OUTROOT=docs/evidence ./tools/http/live.sh
# Optional env:
#   BASE_URL (default http://localhost:8000)
#   OUTROOT  (default docs/evidence)
#   INSTRUCTION (default "Generate a minimal Python CLI project that prints the first 10 Fibonacci numbers and includes a basic test.")
#
# Notes:
# - Do not print or store any secrets. This script never reads .env.live nor echoes environment values.
# - Ensure:
#   - .env has USE_DUMMY_WORKER=False and CODEX_WORKER_IMAGE points to a built image (e.g., codex-worker:latest)
#   - docker-compose mounts /var/run/docker.sock for the backend
#   - backend image includes docker CLI
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
OUTROOT="${OUTROOT:-docs/evidence}"
INSTRUCTION="${INSTRUCTION:-Generate a minimal Python CLI project that prints the first 10 Fibonacci numbers and includes a basic test.}"
TS="$(date -u +%FT%TZ)"
OUTDIR="${OUTROOT}/${TS}/live"

mkdir -p "${OUTDIR}"

echo "[live] BASE_URL=${BASE_URL}"
echo "[live] OUTDIR=${OUTDIR}"

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required. Install jq and re-run." >&2
    exit 1
  fi
}
require_jq

write_excerpt() {
  local result_json="$1"
  local dest_txt="$2"
  jq -r '
    "status: " + (.status // "n/a"),
    "summary: " + (.summary // "n/a"),
    "created_files: " + ((.created_files // []) | join(",")),
    "modified_files: " + ((.modified_files // []) | join(",")),
    "first_error: " + ( ((.errors // []) | (if length>0 then .[0] else "none" end)) | tostring )
  ' <"${result_json}" >"${dest_txt}"
}

http_status_only() {
  # curl wrapper: prints only status code, body to file
  # usage: http_status_only URL OUTFILE
  local url="$1"
  local outfile="$2"
  curl -sS -o "${outfile}" -w "%{http_code}\n" "${url}"
}

fetch_with_retries() {
  # Poll a URL until 200 OK is returned, or timeout (default 5m at 0.5s intervals).
  # usage: fetch_with_retries URL OUTFILE [retries] [sleep_seconds]
  local url="$1"
  local outfile="$2"
  local retries="${3:-600}"       # 600 * 0.5s = 300s (5 minutes)
  local sleep_s="${4:-0.5}"

  local code
  for ((i=1; i<=retries; i++)); do
    code="$(http_status_only "${url}" "${outfile}" || true)"
    if [[ "${code}" == "200" ]]; then
      return 0
    fi
    sleep "${sleep_s}"
  done
  echo "Timeout waiting for ${url}" >&2
  return 1
}

# If a GET /files/{path} response is wrapped like { path, contents },
# unwrap into the raw file content (result.json payload) for downstream jq.
unwrap_result_json() {
  local file="$1"
  if jq -e 'has("contents")' "$file" >/dev/null 2>&1; then
    local tmp
    tmp="$(mktemp)"
    jq -r '.contents' "$file" > "$tmp" && mv "$tmp" "$file"
  fi
}

# L01 Worker Env Presence (via logs in result.json)
run_L01() {
  local dir="${OUTDIR}/L01"
  mkdir -p "${dir}"
  echo "[L01] Creating project to trigger worker (env presence instrumentation)..."
  curl -sS -X POST "${BASE_URL}/api/v1/projects/" \
    -H "Content-Type: application/json" \
    -d "{\"instruction\":\"${INSTRUCTION}\"}" \
    | tee "${dir}/response.json" >/dev/null

  local pid
  pid="$(jq -r '.id' "${dir}/response.json")"
  if [[ -z "${pid}" || "${pid}" == "null" ]]; then
    echo "[L01] ERROR: Could not extract project id" >&2
    exit 1
  fi
  echo -n "${pid}" > "${dir}/project_id.txt"
  echo "[L01] project_id=${pid}"

  echo "[L01] Waiting for .codex/result.json via API..."
  fetch_with_retries "${BASE_URL}/api/v1/${pid}/files/.codex/result.json" "${dir}/result.json"
  unwrap_result_json "${dir}/result.json"

  # Create excerpt
  write_excerpt "${dir}/result.json" "${dir}/result_excerpt.txt"

  # Presence-only validation just for operator view (no secrets printed)
  if ! grep -E 'OPENAI_API_KEY=(present|absent)' -q "${dir}/result.json"; then
    echo "[L01] WARNING: Missing OPENAI_API_KEY presence log in result.json" >&2
  fi
  if ! grep -E 'OPENAI_ORG_ID=(present|absent)' -q "${dir}/result.json"; then
    echo "[L01] WARNING: Missing OPENAI_ORG_ID presence log in result.json" >&2
  fi
  if ! grep -E 'OPENAI_PROJECT=(present|absent)' -q "${dir}/result.json"; then
    echo "[L01] WARNING: Missing OPENAI_PROJECT presence log in result.json" >&2
  fi
}

# L02 Create Project Live (acceptance around result.json and files)
run_L02() {
  local dir="${OUTDIR}/L02"
  mkdir -p "${dir}"

  # Reuse PID from L01 to avoid extra runs
  local pid
  pid="$(cat "${OUTDIR}/L01/project_id.txt")"
  echo "[L02] Using project ${pid} created in L01"

  # Save a copy of L01 response as L02 response for completeness
  cp "${OUTDIR}/L01/response.json" "${dir}/response.json"

  # Fetch result.json and files list
  cp "${OUTDIR}/L01/result.json" "${dir}/result.json"
  write_excerpt "${dir}/result.json" "${dir}/result_excerpt.txt"

  echo "[L02] Listing files..."
  curl -sS "${BASE_URL}/api/v1/${pid}/files" \
    | tee "${dir}/files.json" >/dev/null
}

# L03 List Files Live (redundant but explicit)
run_L03() {
  local dir="${OUTDIR}/L03"
  mkdir -p "${dir}"
  local pid
  pid="$(cat "${OUTDIR}/L01/project_id.txt")"
  echo "[L03] Listing files for ${pid}..."
  curl -sS "${BASE_URL}/api/v1/${pid}/files" \
    | tee "${dir}/files.json" >/dev/null
}

# L04 Get Representative File (app.py)
run_L04() {
  local dir="${OUTDIR}/L04"
  mkdir -p "${dir}"
  local pid
  pid="$(cat "${OUTDIR}/L01/project_id.txt")"
  echo "[L04] Fetching app.py for ${pid}..."
  http_status_only "${BASE_URL}/api/v1/${pid}/files/app.py" "${dir}/app.json" \
    | tee "${dir}/status.txt" >/dev/null
}

# L05 Edit Job Live
run_L05() {
  local dir="${OUTDIR}/L05"
  mkdir -p "${dir}"
  local pid
  pid="$(cat "${OUTDIR}/L01/project_id.txt")"
  echo "[L05] Posting live edit job for ${pid}..."
  curl -sS -X POST "${BASE_URL}/api/v1/${pid}/jobs" \
    -H "Content-Type: application/json" \
    -d '{"job_type":"edit","instruction":"Append a comment line to app.py describing the change."}' \
    | tee "${dir}/response.json" >/dev/null

  echo "[L05] Waiting for updated .codex/result.json..."
  fetch_with_retries "${BASE_URL}/api/v1/${pid}/files/.codex/result.json" "${dir}/result.json"
  unwrap_result_json "${dir}/result.json"
  write_excerpt "${dir}/result.json" "${dir}/result_excerpt.txt"
}

# L06 Error Handling / Timeout (force error via instruction hint)
run_L06() {
  local dir="${OUTDIR}/L06"
  mkdir -p "${dir}"
  echo "[L06] Creating project with force_error hint to validate error path..."
  curl -sS -X POST "${BASE_URL}/api/v1/projects/" \
    -H "Content-Type: application/json" \
    -d '{"instruction":"force_error: provoke a controlled failure"}' \
    | tee "${dir}/response.json" >/dev/null

  local pid
  pid="$(jq -r '.id' "${dir}/response.json")"
  if [[ -z "${pid}" || "${pid}" == "null" ]]; then
    echo "[L06] ERROR: Could not extract project id" >&2
    exit 1
  fi
  echo -n "${pid}" > "${dir}/project_id.txt"
  echo "[L06] project_id=${pid}"

  echo "[L06] Waiting for .codex/result.json (error expected)..."
  fetch_with_retries "${BASE_URL}/api/v1/${pid}/files/.codex/result.json" "${dir}/result.json"
  unwrap_result_json "${dir}/result.json"
  write_excerpt "${dir}/result.json" "${dir}/result_excerpt.txt"

  cat >"${dir}/notes.txt" <<EOF
This test intentionally triggers an error by including "force_error" in the instruction.
Acceptance: result.json.status="error" and errors includes "forced_error".
EOF
}

main() {
  echo "[live] Starting L01–L06..."
  run_L01
  run_L02
  run_L03
  run_L04
  run_L05
  run_L06
  echo "[live] Done. Evidence in ${OUTDIR}/"
}

main "$@"