#!/usr/bin/env bash
# Live Suite - L01 Generate CLI Fibonacci Project (baseline scaffold)
# Preconditions:
#   - USE_DUMMY_WORKER=False in .env
#   - CODEX_WORKER_IMAGE built and set (e.g., codex-worker:latest)
#   - .env.live provides OPENAI_* (presence-only; never printed)
#   - Backend running and can invoke docker
# Usage:
#   BASE_URL=http://localhost:8000 OUTROOT=docs/evidence TS=$(date -u +%FT%TZ) bash tools/http/live_suite/01_generate.sh
# Notes:
#   - This script captures evidence under ${OUTROOT}/${TS}/live/L01
#   - It enforces presence-only logs for OPENAI_* and validates created files on success
set -euo pipefail

# Config
BASE_URL="${BASE_URL:-http://localhost:8000}"
OUTROOT="${OUTROOT:-docs/evidence}"
TS="${TS:-$(date -u +%FT%TZ)}"
OUTDIR="${OUTROOT}/${TS}/live/L01"
INSTRUCTION="${INSTRUCTION:-Generate a minimal Python CLI project that prints the first 10 Fibonacci numbers and includes a basic test.}"

mkdir -p "${OUTDIR}"

echo "[L01] BASE_URL=${BASE_URL}"
echo "[L01] OUTDIR=${OUTDIR}"

# Dependencies
require_tool() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }; }
require_tool jq
require_tool curl

# Helpers
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
  # usage: http_status_only URL OUTFILE
  local url="$1"
  local outfile="$2"
  curl -sS -o "${outfile}" -w "%{http_code}\n" "${url}"
}

fetch_with_retries() {
  # usage: fetch_with_retries URL OUTFILE [retries=600] [sleep_seconds=0.5]
  local url="$1"
  local outfile="$2"
  local retries="${3:-600}"
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

unwrap_result_json() {
  # If response is a wrapper { path, contents }, unwrap contents to raw result.json
  local file="$1"
  if jq -e 'has("contents")' "$file" >/dev/null 2>&1; then
    local tmp
    tmp="$(mktemp)"
    jq -r '.contents' "$file" > "$tmp" && mv "$tmp" "$file"
  fi
}

fail() { echo "[L01] FAIL: $*" >&2; exit 1; }
pass() { echo "[L01] PASS: $*"; }

# 1) Create project (trailing slash avoids 307)
echo "[L01] Creating project..."
curl -sS -X POST "${BASE_URL}/api/v1/projects/" \
  -H "Content-Type: application/json" \
  -d "{\"instruction\":\"${INSTRUCTION}\"}" \
  | tee "${OUTDIR}/response.json" >/dev/null

PID="$(jq -r '.id // empty' "${OUTDIR}/response.json")"
[[ -n "${PID}" ]] || fail "Could not extract project id from response.json"
echo -n "${PID}" > "${OUTDIR}/project_id.txt"
echo "[L01] project_id=${PID}"

# 2) Wait for .codex/result.json and unwrap if needed
echo "[L01] Waiting for .codex/result.json..."
fetch_with_retries "${BASE_URL}/api/v1/${PID}/files/.codex/result.json" "${OUTDIR}/result.json"
unwrap_result_json "${OUTDIR}/result.json"

# 3) Write excerpt for quick review
write_excerpt "${OUTDIR}/result.json" "${OUTDIR}/result_excerpt.txt"

# 4) List files
echo "[L01] Listing files..."
curl -sS "${BASE_URL}/api/v1/${PID}/files" | tee "${OUTDIR}/files.json" >/dev/null

# 5) Presence-only logs validation (no secret values)
#    Must include OPENAI_API_KEY|ORG_ID|PROJECT=(present|absent)
grep -E '"logs"\s*:\s*\[' -q "${OUTDIR}/result.json" || fail "result.json missing logs array"

for var in OPENAI_API_KEY OPENAI_ORG_ID OPENAI_PROJECT; do
  if ! grep -E "${var}=(present|absent)" -q "${OUTDIR}/result.json"; then
    fail "Missing presence-only log for ${var} in result.json"
  fi
done

# 6) Status check and created files (on success)
STATUS="$(jq -r '.status // "n/a"' "${OUTDIR}/result.json")"
if [[ "${STATUS}" != "success" && "${STATUS}" != "error" ]]; then
  fail "Unexpected status=${STATUS}"
fi

if [[ "${STATUS}" == "success" ]]; then
  # Expect minimal Python CLI files to be created by live worker
  for f in "README.md" "app.py" "tests/test_cli.py"; do
    if ! jq -e --arg f "$f" '(.created_files // []) | any(. == $f)' "${OUTDIR}/result.json" >/dev/null; then
      fail "Expected created_files to include ${f}"
    fi
  done
fi

# Optional: capture backend logs (best-effort; avoid secrets)
# Logs should not contain secret values (backend only logs command + presence)
if command -v docker >/dev/null 2>&1; then
  docker logs codex-backend --since 20m > "${OUTDIR}/logs.txt" 2>&1 || true
fi

pass "Generated baseline project. Evidence: ${OUTDIR}"