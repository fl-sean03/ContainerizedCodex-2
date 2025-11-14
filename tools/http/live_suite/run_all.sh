#!/usr/bin/env bash
# Live Validation Suite Orchestrator (L01–L08)
# Orchestrates per-scenario scripts under this directory with a single shared timestamp (TS).
# Requirements: bash, curl, jq
set -euo pipefail

# Inputs
BASE_URL="${BASE_URL:-http://localhost:8000}"
OUTROOT="${OUTROOT:-docs/evidence}"
TS="${TS:-$(date -u +%FT%TZ)}"

export BASE_URL OUTROOT TS

echo "[live_suite] BASE_URL=${BASE_URL}"
echo "[live_suite] OUTROOT=${OUTROOT}"
echo "[live_suite] TS=${TS}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Require dependencies
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required. Install jq and re-run." >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required. Install curl and re-run." >&2
  exit 1
fi

run_step() {
  local id="$1"
  local rel_script="$2"
  local script_path="${SCRIPT_DIR}/${rel_script}"

  echo "[gate] Running ${id} via ${rel_script} ..."
  if ! bash "${script_path}"; then
    echo "[gate] FAIL at ${id}. Evidence so far under ${OUTROOT}/${TS}/live/" >&2
    # Best-effort: capture backend logs for quick triage at suite level
    if command -v docker >/dev/null 2>&1; then
      docker logs codex-backend --since 20m > "${OUTROOT}/${TS}/live/${id}-suite-logs.txt" 2>&1 || true
    fi
    exit 1
  fi
  echo "[gate] PASS ${id}"
}

summarize_suite() {
  local live_root="${OUTROOT}/${TS}/live"
  local summary="${live_root}/summary.txt"
  {
    echo "Live Validation Suite Summary"
    echo "BASE_URL=${BASE_URL}"
    echo "Timestamp root: ${OUTROOT}/${TS}"
    echo ""

    # Print status lines where present
    for S in L01 L02 L03 L04 L05 L06 L07a L07b L08a L08b; do
      case "$S" in
        L07a) path="${live_root}/L07a/result.json" ;;
        L07b) path="${live_root}/L07b/result.json" ;;
        L08a) path="${live_root}/L08a/result.json" ;;
        L08b) path="${live_root}/L08b/result.json" ;;
        *)    path="${live_root}/${S}/result.json" ;;
      esac
      if [[ -f "${path}" ]]; then
        echo -n "${S}: "
        jq -r '.status // "n/a"' "${path}"
      fi
    done
  } > "${summary}"
  echo "[live_suite] Summary written to ${summary}"
}

main() {
  # Ensure root exists
  mkdir -p "${OUTROOT}/${TS}/live"

  # Sequential, gated execution of scenarios
  run_step L01 "01_generate.sh"
  run_step L02 "02_edit_increase_output.sh"
  run_step L03 "03_refactor_split.sh"
  run_step L04 "04_docs_changelog.sh"
  run_step L05 "05_cli_arg_parsing.sh"
  run_step L06 "06_negative_forced_error.sh"
  run_step L07 "07_multi_job_continuity.sh"
  run_step L08 "08_idempotency.sh"

  summarize_suite

  echo "[live_suite] Completed L01–L08. Evidence: ${OUTROOT}/${TS}/live/"
}

main "$@"