#!/usr/bin/env bash
# Live Suite - L08 Idempotency / Run-Twice Behavior (minimal extraneous diffs)
# Purpose:
#   Run the same edit instruction twice and verify the second run is a no-op (or minimal) with modified_files small/empty.
# Preconditions:
#   - L01 success (project_id.txt exists) so we can reuse the same workspace
# Usage:
#   BASE_URL=http://localhost:8000 OUTROOT=docs/evidence TS=$(date -u +%FT%TZ) bash tools/http/live_suite/08_idempotency.sh
# Evidence:
#   ${OUTROOT}/${TS}/live/L08a/{response.json,result.json,result_excerpt.txt,readme.json}
#   ${OUTROOT}/${TS}/live/L08b/{response.json,result.json,result_excerpt.txt,readme.json}
set -euo pipefail

# Config
BASE_URL="${BASE_URL:-http://localhost:8000}"
OUTROOT="${OUTROOT:-docs/evidence}"
TS="${TS:-$(date -u +%FT%TZ)}"
OUTDIR_A="${OUTROOT}/${TS}/live/L08a"
OUTDIR_B="${OUTROOT}/${TS}/live/L08b"
INSTRUCTION="${INSTRUCTION:-Append a trailing newline to README.md if missing; otherwise make no changes.}"

mkdir -p "${OUTDIR_A}" "${OUTDIR_B}"

echo "[L08] BASE_URL=${BASE_URL}"
echo "[L08] OUTDIR_A=${OUTDIR_A}"
echo "[L08] OUTDIR_B=${OUTDIR_B}"

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

fail() { echo "[L08] FAIL: $*" >&2; exit 1; }
pass() { echo "[L08] PASS: $*"; }

# Read project_id from L01
if [[ ! -f "${OUTROOT}/${TS}/live/L01/project_id.txt" ]]; then
  fail "Missing ${OUTROOT}/${TS}/live/L01/project_id.txt. Run L01 first."
fi
PID="$(cat "${OUTROOT}/${TS}/live/L01/project_id.txt")"
[[ -n "${PID}" ]] || fail "Empty project_id in L01/project_id.txt"
echo "[L08] project_id=${PID}"

#########################################
# L08a — First run of idempotent edit   #
#########################################
echo "[L08a] Posting idempotent edit job..."
curl -sS -X POST "${BASE_URL}/api/v1/${PID}/jobs" \
  -H "Content-Type: application/json" \
  -d "{\"job_type\":\"edit\",\"instruction\":\"${INSTRUCTION}\"}" \
  | tee "${OUTDIR_A}/response.json" >/dev/null

echo "[L08a] Waiting for updated .codex/result.json..."
fetch_with_retries "${BASE_URL}/api/v1/${PID}/files/.codex/result.json" "${OUTDIR_A}/result.json"
unwrap_result_json "${OUTDIR_A}/result.json"
write_excerpt "${OUTDIR_A}/result.json" "${OUTDIR_A}/result_excerpt.txt"

STATUS_A="$(jq -r '.status // "n/a"' "${OUTDIR_A}/result.json")"
[[ "${STATUS_A}" == "success" ]] || fail "L08a expected status=success, got ${STATUS_A}"

# Fetch README content after first run
http_status_only "${BASE_URL}/api/v1/${PID}/files/README.md" "${OUTDIR_A}/readme.json" | tee "${OUTDIR_A}/readme_status.txt" >/dev/null
README_A="$(jq -r '.contents // ""' "${OUTDIR_A}/readme.json" || echo "")"

#########################################
# L08b — Second run (should be no-op)   #
#########################################
echo "[L08b] Posting idempotent edit job again (expect no changes)..."
curl -sS -X POST "${BASE_URL}/api/v1/${PID}/jobs" \
  -H "Content-Type: application/json" \
  -d "{\"job_type\":\"edit\",\"instruction\":\"${INSTRUCTION}\"}" \
  | tee "${OUTDIR_B}/response.json" >/dev/null

echo "[L08b] Waiting for updated .codex/result.json..."
fetch_with_retries "${BASE_URL}/api/v1/${PID}/files/.codex/result.json" "${OUTDIR_B}/result.json"
unwrap_result_json "${OUTDIR_B}/result.json"
write_excerpt "${OUTDIR_B}/result.json" "${OUTDIR_B}/result_excerpt.txt"

STATUS_B="$(jq -r '.status // "n/a"' "${OUTDIR_B}/result.json")"
[[ "${STATUS_B}" == "success" ]] || fail "L08b expected status=success, got ${STATUS_B}"

# Fetch README content after second run
http_status_only "${BASE_URL}/api/v1/${PID}/files/README.md" "${OUTDIR_B}/readme.json" | tee "${OUTDIR_B}/readme_status.txt" >/dev/null
README_B="$(jq -r '.contents // ""' "${OUTDIR_B}/readme.json" || echo "")"

# Validation: second run should have minimal/no changes
# - Prefer: modified_files empty
# - Accept: contents unchanged
MODS_LEN="$(jq -r '(.modified_files // []) | length' "${OUTDIR_B}/result.json")"
if [[ "${MODS_LEN}" -ne 0 ]]; then
  if [[ "${README_A}" != "${README_B}" ]]; then
    fail "L08b expected idempotent behavior but README content changed and modified_files length=${MODS_LEN}"
  else
    echo "[L08b] NOTE: modified_files not empty but README content unchanged; treating as pass with warning."
  fi
fi

# Optional: capture backend logs (best-effort; avoid secrets)
if command -v docker >/dev/null 2>&1; then
  docker logs codex-backend --since 20m > "${OUTDIR_B}/logs.txt" 2>&1 || true
fi

pass "Idempotency verified across two runs. Evidence: ${OUTDIR_A} and ${OUTDIR_B}"