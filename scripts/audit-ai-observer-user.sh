#!/usr/bin/env bash
set -u

USER_NAME="${1:-ai-agent}"
USER_DOMAIN="${2:-default}"
CUSTOM_ROLE="${AI_OBSERVER_ROLE:-ai_observer}"
IMPLIED_ROLE="${AI_OBSERVER_IMPLIED_ROLE:-reader}"

FORBIDDEN_ROLES=(
  admin
  member
  manager
  load-balancer_admin
  load-balancer_member
  load-balancer_quota_admin
)

failures=0
warnings=0

need_openstack() {
  if ! command -v openstack >/dev/null 2>&1; then
    echo "ERROR: openstack CLI not found in PATH"
    exit 1
  fi
}

run_openstack() {
  openstack "$@" 2>&1
}

need_openstack

echo "Auditing role assignments for ${USER_NAME} in domain ${USER_DOMAIN}"
assignments="$(run_openstack role assignment list --user-domain "${USER_DOMAIN}" --user "${USER_NAME}" --names)" || {
  echo "ERROR: failed to list role assignments"
  echo "${assignments}"
  exit 1
}

echo "${assignments}"

if ! grep -Eq "(^|[[:space:]|])${CUSTOM_ROLE}([[:space:]|]|$)" <<<"${assignments}"; then
  echo "ERROR: ${USER_NAME} has no ${CUSTOM_ROLE} assignment"
  failures=$((failures + 1))
fi

for role in "${FORBIDDEN_ROLES[@]}"; do
  if grep -Eq "(^|[[:space:]|])${role}([[:space:]|]|$)" <<<"${assignments}"; then
    echo "ERROR: ${USER_NAME} has forbidden write/admin role: ${role}"
    failures=$((failures + 1))
  fi
done

echo
echo "Checking implied role mapping ${CUSTOM_ROLE} -> ${IMPLIED_ROLE}"
implied="$(run_openstack implied role list -f value)" || {
  echo "WARN: could not list implied roles; verify manually with:"
  echo "  openstack implied role list"
  warnings=$((warnings + 1))
  implied=""
}

if [[ -n "${implied}" ]]; then
  echo "${implied}"
  if ! grep -Eq "${CUSTOM_ROLE}.*${IMPLIED_ROLE}|${IMPLIED_ROLE}.*${CUSTOM_ROLE}" <<<"${implied}"; then
    echo "ERROR: could not verify ${CUSTOM_ROLE} implies ${IMPLIED_ROLE}"
    failures=$((failures + 1))
  fi
fi

if (( failures > 0 )); then
  echo "Role audit failed with ${failures} error(s)."
  exit 1
fi

if (( warnings > 0 )); then
  echo "Role audit passed with ${warnings} warning(s)."
else
  echo "Role audit passed."
fi
