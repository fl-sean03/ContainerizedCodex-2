#!/usr/bin/env bash
# Live Suite - L07 Multi-file edit session (two consecutive jobs) verifying continuity
# Purpose:
#   - First edit: create utils.py with format_sequence(seq) helper
#   - Second edit: update app.py to import and use format_sequence from utils.py
# Preconditions:
#   - L01 success (project_id.txt exists) so we can reuse the same workspace
# Usage:
#   BASE_URL=http://localhost:8000 OUTROOT=docs/evidence TS=$(date -u +%FT%TZ) bash tools/http/live_suite/07_multi_job_continuity.sh
# Evidence:
#   ${OUTROOT}/${TS}/live/L07a/{response.json,result.json,result_excerpt.txt,utils.json}
#   ${OUTROOT}/${TS}/live/L07b/{response.json,result.json,result_excerpt.txt,app.json}
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
OUTROOT="${OUTROOT:-docs/evidence}"
TS="${TS:-$(date -u +%FT%TZ)}"
OUTDIR_A="${OUTROOT}/${TS}/live/L07a"
OUTDIR_B="${OUTROOT}/${TS}/live/L07b"
INSTR_CREATE_UTILS="${INSTR_CREATE_UTILS:-Add a module utils.py with helper function format_sequence(seq) that returns a comma-joined string.}"
INSTR_USE_UTILS="${INSTR_USE_UTILS:-Update app.py to use format_sequence from utils.py for printing.}"

mkdir -p "${OUTDIR_A}" "${OUTDIR_B}"

echo "[L07] BASE_URL=${BASE_URL}"
echo "[L07] OUTDIR_A=${OUTDIR_A}"
echo "[L07] OUTDIR_B=${OUTDIR_B}"

require_tool() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }; }
require_tool jq
require_tool curl

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
  local url="$1"
  local outfile="$2"
  curl -sS -o "${outfile}" -w "%{http_code}\n" "${url}"
}

fetch_with_retries() {
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
  local file="$1"
  if jq -e 'has("contents")' "$file" >/dev/null 2>&1; then
    local tmp
    tmp="$(mktemp)"
    jq -r '.contents' "$file" > "$tmp" && mv "$tmp" "$file"
  fi
}

fail() { echo "[L07] FAIL: $*" >&2; exit 1; }
pass() { echo "[L07] PASS: $*"; }

if [[ ! -f "${OUTROOT}/${TS}/live/L01/project_id.txt" ]]; then
  fail "Missing ${OUTROOT}/${TS}/live/L01/project_id.txt. Run L01 first."
fi
PID="$(cat "${OUTROOT}/${TS}/live/L01/project_id.txt")"
[[ -n "${PID}" ]] || fail "Empty project_id in L01/project_id.txt"
echo "[L07] project_id=${PID}"

echo "[L07a] Posting edit job to create utils.py..."
curl -sS -X POST "${BASE_URL}/api/v1/${PID}/jobs" \
  -H "Content-Type: application/json" \
  -d "{\"job_type\":\"edit\",\"instruction\":\"${INSTR_CREATE_UTILS}\"}" \
  | tee "${OUTDIR_A}/response.json" >/dev/null

echo "[L07a] Waiting for updated .codex/result.json..."
fetch_with_retries "${BASE_URL}/api/v1/${PID}/files/.codex/result.json" "${OUTDIR_A}/result.json"
unwrap_result_json "${OUTDIR_A}/result.json"
write_excerpt "${OUTDIR_A}/result.json" "${OUTDIR_A}/result_excerpt.txt"

STATUS_A="$(jq -r '.status // "n/a"' "${OUTDIR_A}/result.json")"
[[ "${STATUS_A}" == "success" ]] || fail "L07a expected status=success, got ${STATUS_A}"

jq -e '(.created_files // []) | any(. == "utils.py")' "${OUTDIR_A}/result.json" >/dev/null \
  || echo "[L07a] NOTE: utils.py not in created_files; may have been modified if it already existed."

echo "[L07a] Fetching utils.py..."
http_status_only "${BASE_URL}/api/v1/${PID}/files/utils.py" "${OUTDIR_A}/utils.json" | tee "${OUTDIR_A}/utils_status.txt" >/dev/null
UTILS_TXT="$(jq -r '.contents // ""' "${OUTDIR_A}/utils.json")"
if ! echo "${UTILS_TXT}" | grep -E '^def[[:space:]]+format_sequence\(' >/dev/null 2>&1; then
  fail "L07a utils.py does not appear to define format_sequence()"
fi

if command -v docker >/dev/null 2>&1; then
  docker logs codex-backend --since 20m > "${OUTDIR_A}/logs.txt" 2>&1 || true
fi

echo "[L07b] Posting edit job to update app.py to use format_sequence from utils.py..."
curl -sS -X POST "${BASE_URL}/api/v1/${PID}/jobs" \
  -H "Content-Type: application/json" \
  -d "{\"job_type\":\"edit\",\"instruction\":\"${INSTR_USE_UTILS}\"}" \
  | tee "${OUTDIR_B}/response.json" >/dev/null

echo "[L07b] Waiting for updated .codex/result.json..."
fetch_with_retries "${BASE_URL}/api/v1/${PID}/files/.codex/result.json" "${OUTDIR_B}/result.json"
unwrap_result_json "${OUTDIR_B}/result.json"
write_excerpt "${OUTDIR_B}/result.json" "${OUTDIR_B}/result_excerpt.txt"

STATUS_B="$(jq -r '.status // "n/a"' "${OUTDIR_B}/result.json")"
[[ "${STATUS_B}" == "success" ]] || fail "L07b expected status=success, got ${STATUS_B}"

jq -e '(.modified_files // []) | any(. == "app.py")' "${OUTDIR_B}/result.json" >/dev/null \
  || fail "L07b expected modified_files to include app.py"

echo "[L07b] Fetching app.py..."
http_status_only "${BASE_URL}/api/v1/${PID}/files/app.py" "${OUTDIR_B}/app.json" | tee "${OUTDIR_B}/app_status.txt" >/dev/null
APP_TXT="$(jq -r '.contents // ""' "${OUTDIR_B}/app.json")"

if ! echo "${APP_TXT}" | grep -E 'from[[:space:]]+utils[[:space:]]+import[[:space:]]+format_sequence' >/dev/null 2>&1; then
  fail "L07b app.py does not import format_sequence from utils.py"
fi

if ! echo "${APP_TXT}" | grep -E 'format_sequence\(' >/dev/null 2>&1; then
  fail "L07b app.py does not appear to call format_sequence()"
fi

if command -v docker >/dev/null 2>&1; then
  docker logs codex-backend --since 20m > "${OUTDIR_B}/logs.txt" 2>&1 || true
fi

pass "L07 multi-job continuity verified. Evidence: ${OUTROOT}/${TS}/live/L07a and L07b"