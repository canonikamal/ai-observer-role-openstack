#!/usr/bin/env bash
set -u

if (( $# != 2 )); then
  echo "Usage: $0 <project-scoped-rc> <system-scoped-rc>"
  exit 2
fi

PROJECT_RC="$1"
SYSTEM_RC="$2"

passed=0
skipped=0
failed=0

run_probe() {
  local scope="$1"
  local rc_file="$2"
  local name="$3"
  shift 3

  if [[ ! -r "${rc_file}" ]]; then
    echo "FAIL [${scope}] ${name}: cannot read RC file ${rc_file}"
    failed=$((failed + 1))
    return
  fi

  local output
  output="$(bash -c 'source "$1"; shift; "$@"' _ "${rc_file}" "$@" 2>&1)"
  local rc=$?

  if (( rc == 0 )); then
    echo "PASS [${scope}] ${name}"
    passed=$((passed + 1))
    return
  fi

  if grep -Eiq "not an openstack command|unknown command|endpoint.*not found|no service catalog|service .* not found|public endpoint|resource could not be found|is not enabled" <<<"${output}"; then
    echo "SKIP [${scope}] ${name}: service/command unavailable"
    skipped=$((skipped + 1))
    return
  fi

  echo "FAIL [${scope}] ${name}"
  echo "${output}"
  failed=$((failed + 1))
}

run_probe project "${PROJECT_RC}" "token issue" openstack token issue
run_probe project "${PROJECT_RC}" "network list" openstack network list
run_probe project "${PROJECT_RC}" "subnet list" openstack subnet list
run_probe project "${PROJECT_RC}" "port list" openstack port list
run_probe project "${PROJECT_RC}" "router list" openstack router list
run_probe project "${PROJECT_RC}" "image list" openstack image list
run_probe project "${PROJECT_RC}" "loadbalancer list" openstack loadbalancer list
run_probe project "${PROJECT_RC}" "listener list" openstack loadbalancer listener list
run_probe project "${PROJECT_RC}" "pool list" openstack loadbalancer pool list
run_probe project "${PROJECT_RC}" "provider list" openstack loadbalancer provider list

run_probe system "${SYSTEM_RC}" "token issue" openstack token issue
run_probe system "${SYSTEM_RC}" "server list all projects" openstack server list --all-projects
run_probe system "${SYSTEM_RC}" "hypervisor list" openstack hypervisor list
run_probe system "${SYSTEM_RC}" "compute service list" openstack compute service list
run_probe system "${SYSTEM_RC}" "volume list all projects" openstack volume list --all-projects
run_probe system "${SYSTEM_RC}" "volume service list" openstack volume service list

echo "Read smoke summary: ${passed} passed, ${skipped} skipped, ${failed} failed."

if (( failed > 0 )); then
  exit 1
fi
