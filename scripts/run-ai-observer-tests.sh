#!/usr/bin/env bash
set -u

if (( $# < 2 || $# > 4 )); then
  echo "Usage: $0 <project-scoped-rc> <system-scoped-rc> [ai-user] [user-domain]"
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_RC="$1"
SYSTEM_RC="$2"
AI_USER="${3:-ai-agent}"
USER_DOMAIN="${4:-default}"

status=0

run_step() {
  local name="$1"
  shift
  echo
  echo "== ${name} =="
  "$@"
  local rc=$?
  if (( rc != 0 )); then
    echo "Step failed: ${name} (exit ${rc})"
    status=1
  fi
}

run_step "Static override validation" "${ROOT_DIR}/scripts/validate-policy-overrides.py"
run_step "AI user role audit" "${ROOT_DIR}/scripts/audit-ai-observer-user.sh" "${AI_USER}" "${USER_DOMAIN}"
run_step "Read access smoke test" "${ROOT_DIR}/scripts/smoke-read-access.sh" "${PROJECT_RC}" "${SYSTEM_RC}"
run_step "Mutation denial smoke test" "${ROOT_DIR}/scripts/smoke-mutation-denied.sh" "${PROJECT_RC}" "${SYSTEM_RC}"

echo
if (( status == 0 )); then
  echo "AI observer test suite completed successfully."
else
  echo "AI observer test suite completed with failures or inconclusive checks."
fi

exit "${status}"
