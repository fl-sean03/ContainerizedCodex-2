#!/usr/bin/env bash
# Codex Orchestrator - Mocked mode test runner
# Runs M01–M07 (and templates for M08, M09) against a running backend in dummy mode.
# Requirements: bash, curl, jq
# Usage examples:
#   chmod +x tools/http/mocked.sh
#   BASE_URL=http://localhost:8000 OUTROOT=docs/evidence ./tools/http/mocked.sh
# Optional env:
#   BASE_URL (default http://localhost:8000)
#   OUTROOT  (default docs/evidence)
#   INSTRUCTION (default "Generate a minimal Python CLI project that prints the first 10 Fibonacci numbers and includes a basic test.")
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
OUTROOT="${OUTROOT:-docs/evidence}"
INSTRUCTION="${INSTRUCTION:-Generate a minimal Python CLI project that prints the first 10 Fibonacci numbers and includes a basic test.}"
TS="$(date -u +%FT%TZ)"
OUTDIR="${OUTROOT}/${TS}/mocked"

mkdir -p "${OUTDIR}"

echo "[mocked] BASE_URL=${BASE_URL}"
echo "[mocked] OUTDIR=${OUTDIR}"

jq_check() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required. Install jq and re-run." >&2
    exit 1
  fi
}
jq_check

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

# M01 Create Project (happy path)
run_M01() {
  local dir="${OUTDIR}/M01"
  mkdir -p "${dir}"
  echo "[M01] Creating project..."
  curl -sS -X POST "${BASE_URL}/api/v1/projects/" \
    -H "Content-Type: application/json" \
    -d "{\"instruction\":\"${INSTRUCTION}\"}" \
    | tee "${dir}/response.json" >/dev/null

  local pid
  pid="$(jq -r '.id' "${dir}/response.json")"
  if [[ -z "${pid}" || "${pid}" == "null" ]]; then
    echo "[M01] ERROR: Could not extract project id" >&2
    exit 1
  fi
  echo -n "${pid}" > "${dir}/project_id.txt"
  echo "[M01] project_id=${pid}"

  # result.json via API (for evidence)
  mkdir -p "${OUTDIR}/M09" # for artifact checks later
  curl -sS "${BASE_URL}/api/v1/${pid}/files/.codex/result.json" \
    | tee "${OUTDIR}/M09/result.json" >/dev/null || true
  if [[ -f "${OUTDIR}/M09/result.json" ]]; then
    write_excerpt "${OUTDIR}/M09/result.json" "${OUTDIR}/M09/result_excerpt.txt"
  fi

  # Also save a copy in M01 for quick review
  if [[ -f "${OUTDIR}/M09/result.json" ]]; then
    cp "${OUTDIR}/M09/result.json" "${dir}/result.json"
    write_excerpt "${dir}/result.json" "${dir}/result_excerpt.txt"
  fi
}

# M02 List Files
run_M02() {
  local dir="${OUTDIR}/M02"
  mkdir -p "${dir}"
  local pid
  pid="$(cat "${OUTDIR}/M01/project_id.txt")"
  echo "[M02] Listing files for ${pid}..."
  curl -sS "${BASE_URL}/api/v1/${pid}/files" \
    | tee "${dir}/files.json" >/dev/null
}

# M03 Get File (app.py)
run_M03() {
  local dir="${OUTDIR}/M03"
  mkdir -p "${dir}"
  local pid
  pid="$(cat "${OUTDIR}/M01/project_id.txt")"
  echo "[M03] Fetching app.py for ${pid}..."
  curl -sS "${BASE_URL}/api/v1/${pid}/files/app.py" \
    | tee "${dir}/app.json" >/dev/null
}

# M04 Edit Job
run_M04() {
  local dir="${OUTDIR}/M04"
  mkdir -p "${dir}"
  local pid
  pid="$(cat "${OUTDIR}/M01/project_id.txt")"
  echo "[M04] Posting edit job for ${pid}..."
  curl -sS -X POST "${BASE_URL}/api/v1/${pid}/jobs" \
    -H "Content-Type: application/json" \
    -d '{"job_type":"edit","instruction":"Append a comment line to app.py describing the change."}' \
    | tee "${dir}/response.json" >/dev/null

  # Grab result.json (dummy worker)
  curl -sS "${BASE_URL}/api/v1/${pid}/files/.codex/result.json" \
    | tee "${dir}/result.json" >/dev/null || true
  if [[ -f "${dir}/result.json" ]]; then
    write_excerpt "${dir}/result.json" "${dir}/result_excerpt.txt"
  fi
}

# M05 Traversal Blocked
run_M05() {
  local dir="${OUTDIR}/M05"
  mkdir -p "${dir}"
  local pid
  pid="$(cat "${OUTDIR}/M01/project_id.txt")"
  echo "[M05] Attempt traversal (expect 400)..."
  curl -sS -o "${dir}/response.json" -w "%{http_code}\n" \
    "${BASE_URL}/api/v1/${pid}/files/%2e%2e%2Fetc%2Fpasswd" \
    | tee "${dir}/status.txt" >/dev/null || true
}

# M06 Absolute Blocked
run_M06() {
  local dir="${OUTDIR}/M06"
  mkdir -p "${dir}"
  local pid
  pid="$(cat "${OUTDIR}/M01/project_id.txt")"
  echo "[M06] Attempt absolute path (expect 400)..."
  curl -sS -o "${dir}/response.json" -w "%{http_code}\n" \
    "${BASE_URL}/api/v1/${pid}/files/%2Fetc%2Fpasswd" \
    | tee "${dir}/status.txt" >/dev/null || true
}

# M07 Safe Nonexistent
run_M07() {
  local dir="${OUTDIR}/M07"
  mkdir -p "${dir}"
  local pid
  pid="$(cat "${OUTDIR}/M01/project_id.txt")"
  echo "[M07] Read safe-but-missing file (expect 404)..."
  curl -sS -o "${dir}/response.json" -w "%{http_code}\n" \
    "${BASE_URL}/api/v1/${pid}/files/does-not-exist.txt" \
    | tee "${dir}/status.txt" >/dev/null || true
}

# M08 Symlink Escape Blocked (template - requires setup)
run_M08_template() {
  local dir="${OUTDIR}/M08"
  mkdir -p "${dir}"
  cat > "${dir}/notes.txt" <<'EOF'
M08 Template Instructions:
1) Create a symlink inside the workspace pointing outside, e.g.:
   host$ WS=./backend/workspaces/<project_id>
   host$ mkdir -p "$WS/symlinked-escape"
   host$ ln -s /tmp "$WS/symlinked-escape/outside"
2) Then attempt:
   GET /api/v1/{project_id}/files/symlinked-escape/outside/secret
Expected: HTTP 400 invalid/unsafe path
EOF
  echo "[M08] Template written at ${dir}/notes.txt"
}

# M09 Workspace Artifacts Check
run_M09() {
  local dir="${OUTDIR}/M09"
  mkdir -p "${dir}"
  local pid
  pid="$(cat "${OUTDIR}/M01/project_id.txt")"
  echo "[M09] Fetching .codex/result.json and file list..."
  curl -sS "${BASE_URL}/api/v1/${pid}/files/.codex/result.json" \
    | tee "${dir}/result.json" >/dev/null || true
  if [[ -f "${dir}/result.json" ]]; then
    write_excerpt "${dir}/result.json" "${dir}/result_excerpt.txt"
  fi
  curl -sS "${BASE_URL}/api/v1/${pid}/files" \
    | tee "${dir}/files.json" >/dev/null
}

main() {
  echo "[mocked] Starting M01–M09..."
  run_M01
  run_M02
  run_M03
  run_M04
  run_M05
  run_M06
  run_M07
  run_M08_template
  run_M09
  echo "[mocked] Done. Evidence in ${OUTDIR}/"
}

main "$@"