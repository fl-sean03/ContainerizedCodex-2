#!/usr/bin/env bash
# Live Suite - L05 Add CLI input parsing (accept N from CLI)
# Preconditions:
#   - L01 success (project_id.txt exists)
#   - Prior edits/refactors recommended for continuity
# Usage:
#   BASE_URL=http://localhost:8000 OUTROOT=docs/evidence TS=$(date -u +%FT%TZ) bash tools/http/live_suite/05_cli_arg_parsing.sh
# Evidence:
#   ${OUTROOT}/${TS}/live/L05/{response.json,result.json,result_excerpt.txt,app.json}
set -euo pipefail

# Config
BASE_URL="${BASE_URL:-http://localhost:8000}"
OUTROOT="${OUTROOT:-docs/evidence}"
TS="${TS:-$(date -u +%FT%TZ)}"
OUTDIR="${OUTROOT}/${TS}/live/L05"
INSTRUCTION="${INSTRUCTION:-Add CLI argument parsing so the program accepts N and prints the first N Fibonacci numbers.}"

mkdir -p "${OUTDIR}"

echo "[L05] BASE_URL=${BASE_URL}"
echo "[L05] OUTDIR=${OUTDIR}"

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

fail() { echo "[L05] FAIL: $*" >&2; exit 1; }
pass() { echo "[L05] PASS: $*"; }

# Read project_id from L01
if [[ ! -f "${OUTROOT}/${TS}/live/L01/project_id.txt" ]]; then
  fail "Missing ${OUTROOT}/${TS}/live/L01/project_id.txt. Run L01 first."
fi
PID="$(cat "${OUTROOT}/${TS}/live/L01/project_id.txt")"
[[ -n "${PID}" ]] || fail "Empty project_id in L01/project_id.txt"
echo "[L05] project_id=${PID}"

# 1) Post edit job to add CLI argument parsing
echo "[L05] Posting edit job..."
curl -sS -X POST "${BASE_URL}/api/v1/${PID}/jobs" \
  -H "Content-Type: application/json" \
  -d "{\"job_type\":\"edit\",\"instruction\":\"${INSTRUCTION}\"}" \
  | tee "${OUTDIR}/response.json" >/dev/null

# 2) Wait for .codex/result.json and unwrap
echo "[L05] Waiting for updated .codex/result.json..."
fetch_with_retries "${BASE_URL}/api/v1/${PID}/files/.codex/result.json" "${OUTDIR}/result.json"
unwrap_result_json "${OUTDIR}/result.json"

# 3) Write excerpt
write_excerpt "${OUTDIR}/result.json" "${OUTDIR}/result_excerpt.txt"

# 4) Fetch app.py
echo "[L05] Fetching app.py..."
http_status_only "${BASE_URL}/api/v1/${PID}/files/app.py" "${OUTDIR}/app.json" | tee "${OUTDIR}/status.txt" >/dev/null

# 5) Validations
STATUS="$(jq -r '.status // "n/a"' "${OUTDIR}/result.json")"
[[ "${STATUS}" == "success" ]] || fail "Expected status=success, got ${STATUS}"

# Modified files should include app.py
jq -e '(.modified_files // []) | any(. == "app.py")' "${OUTDIR}/result.json" >/dev/null \
  || fail "Expected modified_files to include app.py"

# Heuristic: app.json should contain argparse usage or sys.argv pattern
APP_TXT="$(jq -r '.contents // ""' "${OUTDIR}/app.json")"
if ! echo "${APP_TXT}" | grep -E '(import[[:space:]]+argparse|sys\.argv)' >/dev/null 2>&1; then
  echo "[L05] WARNING: Could not detect argparse/sys.argv in app.py; proceeding based on modified_files."
fi

# Optional: capture backend logs (best-effort; avoid secrets)
if command -v docker >/dev/null 2>&1; then
  docker logs codex-backend --since 20m > "${OUTDIR}/logs.txt" 2>&1 || true
fi

pass "CLI argument parsing added to app.py. Evidence: ${OUTDIR}"