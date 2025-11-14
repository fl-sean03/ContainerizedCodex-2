#!/usr/bin/env bash
# Live Suite - L03 Refactor: split app.py into fibonacci.py + app.py import
# Preconditions:
#   - L01 success (project_id.txt exists)
#   - L02 success recommended (but not strictly required)
# Usage:
#   BASE_URL=http://localhost:8000 OUTROOT=docs/evidence TS=$(date -u +%FT%TZ) bash tools/http/live_suite/03_refactor_split.sh
# Evidence:
#   ${OUTROOT}/${TS}/live/L03/{response.json,result.json,result_excerpt.txt,app.json,fibonacci.json}
set -euo pipefail

# Config
BASE_URL="${BASE_URL:-http://localhost:8000}"
OUTROOT="${OUTROOT:-docs/evidence}"
TS="${TS:-$(date -u +%FT%TZ)}"
OUTDIR="${OUTROOT}/${TS}/live/L03"
INSTRUCTION="${INSTRUCTION:-Refactor by moving fibonacci() to fibonacci.py and have app.py import and use it.}"

mkdir -p "${OUTDIR}"

echo "[L03] BASE_URL=${BASE_URL}"
echo "[L03] OUTDIR=${OUTDIR}"

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

fail() { echo "[L03] FAIL: $*" >&2; exit 1; }
pass() { echo "[L03] PASS: $*"; }

# Read project_id from L01
L01_DIR="${OUTROOT}/${TS}/live/L01"
[[ -f "${L01_DIR}/project_id.txt" ]] || fail "Missing ${L01_DIR}/project_id.txt. Run L01 first."
PID="$(cat "${L01_DIR}/project_id.txt")"
[[ -n "${PID}" ]] || fail "Empty project_id in ${L01_DIR}/project_id.txt"
echo "[L03] project_id=${PID}"

# 1) Post edit job with refactor instruction
echo "[L03] Posting refactor edit job..."
curl -sS -X POST "${BASE_URL}/api/v1/${PID}/jobs" \
  -H "Content-Type: application/json" \
  -d "{\"job_type\":\"edit\",\"instruction\":\"${INSTRUCTION}\"}" \
  | tee "${OUTDIR}/response.json" >/dev/null

# 2) Wait for .codex/result.json and unwrap
echo "[L03] Waiting for updated .codex/result.json..."
fetch_with_retries "${BASE_URL}/api/v1/${PID}/files/.codex/result.json" "${OUTDIR}/result.json"
unwrap_result_json "${OUTDIR}/result.json"

# 3) Write excerpt
write_excerpt "${OUTDIR}/result.json" "${OUTDIR}/result_excerpt.txt"

# 4) Fetch fibonacci.py and app.py
echo "[L03] Fetching fibonacci.py and app.py..."
http_status_only "${BASE_URL}/api/v1/${PID}/files/fibonacci.py" "${OUTDIR}/fibonacci.json" | tee "${OUTDIR}/fibonacci_status.txt" >/dev/null
http_status_only "${BASE_URL}/api/v1/${PID}/files/app.py" "${OUTDIR}/app.json" | tee "${OUTDIR}/app_status.txt" >/dev/null

# 5) Validations
STATUS="$(jq -r '.status // "n/a"' "${OUTDIR}/result.json")"
[[ "${STATUS}" == "success" ]] || fail "Expected status=success, got ${STATUS}"

# Created files should include fibonacci.py (if newly created)
jq -e '(.created_files // []) | any(. == "fibonacci.py")' "${OUTDIR}/result.json" >/dev/null \
  || echo "[L03] NOTE: fibonacci.py may have been modified instead of created if it existed."

# app.py should import fibonacci
if ! jq -r '.contents // ""' "${OUTDIR}/app.json" | grep -E 'from[[:space:]]+fibonacci[[:space:]]+import[[:space:]]+fibonacci' >/dev/null 2>&1; then
  fail "app.py does not appear to import fibonacci from fibonacci.py"
fi

# fibonacci.py should define fibonacci()
if ! jq -r '.contents // ""' "${OUTDIR}/fibonacci.json" | grep -E '^def[[:space:]]+fibonacci\(' >/dev/null 2>&1; then
  fail "fibonacci.py does not appear to define fibonacci()"
fi

# Optional: capture backend logs (best-effort; avoid secrets)
if command -v docker >/dev/null 2>&1; then
  docker logs codex-backend --since 20m > "${OUTDIR}/logs.txt" 2>&1 || true
fi

pass "Refactor completed with fibonacci.py module and app.py import. Evidence: ${OUTDIR}"