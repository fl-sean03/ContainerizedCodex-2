#!/usr/bin/env bash
# Live Suite - L04 README enhancements and CHANGELOG addition
# Preconditions:
#   - L01 success (project_id.txt exists)
#   - L02/L03 recommended for continuity
# Usage:
#   BASE_URL=http://localhost:8000 OUTROOT=docs/evidence TS=$(date -u +%FT%TZ) bash tools/http/live_suite/04_docs_changelog.sh
# Evidence:
#   ${OUTROOT}/${TS}/live/L04/{response.json,result.json,result_excerpt.txt,readme.json,changelog.json}
set -euo pipefail

# Config
BASE_URL="${BASE_URL:-http://localhost:8000}"
OUTROOT="${OUTROOT:-docs/evidence}"
TS="${TS:-$(date -u +%FT%TZ)}"
OUTDIR="${OUTROOT}/${TS}/live/L04"
INSTRUCTION="${INSTRUCTION:-Enhance README with usage instructions and create CHANGELOG.md with initial entry.}"

mkdir -p "${OUTDIR}"

echo "[L04] BASE_URL=${BASE_URL}"
echo "[L04] OUTDIR=${OUTDIR}"

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

fail() { echo "[L04] FAIL: $*" >&2; exit 1; }
pass() { echo "[L04] PASS: $*"; }

# Read project_id from L01
if [[ ! -f "${OUTROOT}/${TS}/live/L01/project_id.txt" ]]; then
  fail "Missing ${OUTROOT}/${TS}/live/L01/project_id.txt. Run L01 first."
fi
PID="$(cat "${OUTROOT}/${TS}/live/L01/project_id.txt")"
[[ -n "${PID}" ]] || fail "Empty project_id in L01/project_id.txt"
echo "[L04] project_id=${PID}"

# 1) Post edit job for README enhancements and CHANGELOG.md
echo "[L04] Posting edit job..."
curl -sS -X POST "${BASE_URL}/api/v1/${PID}/jobs" \
  -H "Content-Type: application/json" \
  -d "{\"job_type\":\"edit\",\"instruction\":\"${INSTRUCTION}\"}" \
  | tee "${OUTDIR}/response.json" >/dev/null

# 2) Wait for .codex/result.json and unwrap
echo "[L04] Waiting for updated .codex/result.json..."
fetch_with_retries "${BASE_URL}/api/v1/${PID}/files/.codex/result.json" "${OUTDIR}/result.json"
unwrap_result_json "${OUTDIR}/result.json"

# 3) Write excerpt
write_excerpt "${OUTDIR}/result.json" "${OUTDIR}/result_excerpt.txt"

# 4) Fetch README.md and CHANGELOG.md
echo "[L04] Fetching README.md and CHANGELOG.md..."
http_status_only "${BASE_URL}/api/v1/${PID}/files/README.md" "${OUTDIR}/readme.json" | tee "${OUTDIR}/readme_status.txt" >/dev/null
http_status_only "${BASE_URL}/api/v1/${PID}/files/CHANGELOG.md" "${OUTDIR}/changelog.json" | tee "${OUTDIR}/changelog_status.txt" >/dev/null

# 5) Validations
STATUS="$(jq -r '.status // "n/a"' "${OUTDIR}/result.json")"
[[ "${STATUS}" == "success" ]] || fail "Expected status=success, got ${STATUS}"

# created_files should include CHANGELOG.md
jq -e '(.created_files // []) | any(. == "CHANGELOG.md")' "${OUTDIR}/result.json" >/dev/null \
  || fail "Expected created_files to include CHANGELOG.md"

# modified_files should include README.md
jq -e '(.modified_files // []) | any(. == "README.md")' "${OUTDIR}/result.json" >/dev/null 2>&1 \
  || echo "[L04] NOTE: README.md may have been created rather than modified."

# README content heuristics
READMETXT="$(jq -r '.contents // ""' "${OUTDIR}/readme.json")"
echo "${READMETXT}" | grep -E -i '(^##[[:space:]]*Usage)|(^##[[:space:]]*How to run)|(^Usage:)' >/dev/null 2>&1 \
  || echo "[L04] WARNING: README did not contain Usage/how-to-run markers."

# Optional: capture backend logs (best-effort; avoid secrets)
if command -v docker >/dev/null 2>&1; then
  docker logs codex-backend --since 20m > "${OUTDIR}/logs.txt" 2>&1 || true
fi

pass "README enhanced and CHANGELOG added. Evidence: ${OUTDIR}"