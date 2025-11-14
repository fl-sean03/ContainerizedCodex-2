#!/usr/bin/env bash
# Live Suite - L06 Negative Path: Forced Error Handling
# Purpose:
#   Create a new project with an instruction that intentionally triggers a structured error.
# Preconditions:
#   - Backend running in live mode (USE_DUMMY_WORKER=False)
# Usage:
#   BASE_URL=http://localhost:8000 OUTROOT=docs/evidence TS=$(date -u +%FT%TZ) bash tools/http/live_suite/06_negative_forced_error.sh
# Evidence:
#   ${OUTROOT}/${TS}/live/L06/{response.json,project_id.txt,result.json,result_excerpt.txt,notes.txt}
set -euo pipefail

# Config
BASE_URL="${BASE_URL:-http://localhost:8000}"
OUTROOT="${OUTROOT:-docs/evidence}"
TS="${TS:-$(date -u +%FT%TZ)}"
OUTDIR="${OUTROOT}/${TS}/live/L06"
INSTRUCTION="${INSTRUCTION:-force_error: provoke a controlled failure}"

mkdir -p "${OUTDIR}"

echo "[L06] BASE_URL=${BASE_URL}"
echo "[L06] OUTDIR=${OUTDIR}"

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

fail() { echo "[L06] FAIL: $*" >&2; exit 1; }
pass() { echo "[L06] PASS: $*"; }

# 1) Create project with forced-error instruction (trailing slash avoids 307)
echo "[L06] Creating project with forced error instruction..."
curl -sS -X POST "${BASE_URL}/api/v1/projects/" \
  -H "Content-Type: application/json" \
  -d "{\"instruction\":\"${INSTRUCTION}\"}" \
  | tee "${OUTDIR}/response.json" >/dev/null

PID="$(jq -r '.id // empty' "${OUTDIR}/response.json")"
[[ -n "${PID}" ]] || fail "Could not extract project id from response.json"
echo -n "${PID}" > "${OUTDIR}/project_id.txt"
echo "[L06] project_id=${PID}"

# 2) Wait for .codex/result.json and unwrap if needed
echo "[L06] Waiting for .codex/result.json (error expected)..."
fetch_with_retries "${BASE_URL}/api/v1/${PID}/files/.codex/result.json" "${OUTDIR}/result.json"
unwrap_result_json "${OUTDIR}/result.json"

# 3) Write excerpt
write_excerpt "${OUTDIR}/result.json" "${OUTDIR}/result_excerpt.txt"

# 4) Notes
cat > "${OUTDIR}/notes.txt" <<'EOF'
This scenario intentionally triggers an error. Acceptance:
- result.json.status == "error"
- errors contains "forced_error"
EOF

# 5) Validations
STATUS="$(jq -r '.status // "n/a"' "${OUTDIR}/result.json")"
[[ "${STATUS}" == "error" ]] || fail "Expected status=error, got ${STATUS}"

# errors must include "forced_error"
jq -e '(.errors // []) | any(. == "forced_error")' "${OUTDIR}/result.json" >/dev/null \
  || fail 'Expected errors to include "forced_error"'

# Optional: capture backend logs (best-effort; avoid secrets)
if command -v docker >/dev/null 2>&1; then
  docker logs codex-backend --since 20m > "${OUTDIR}/logs.txt" 2>&1 || true
fi

pass "Forced error captured as structured result. Evidence: ${OUTDIR}"