#!/usr/bin/env bash
set -u

if (( $# != 2 )); then
  echo "Usage: $0 <project-scoped-rc> <system-scoped-rc>"
  exit 2
fi

PROJECT_RC="$1"
SYSTEM_RC="$2"
PROBE_ID="00000000-0000-4000-8000-000000000042"
PROBE_NAME="ai-observer-policy-probe-${PROBE_ID}"

passed=0
skipped=0
failed=0
inconclusive=0

run_denial_probe() {
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

  if grep -Eiq "policy doesn't allow|disallowed by policy|forbidden|not authorized|HttpException: 403|HTTP 403|status code: 403|403 Forbidden" <<<"${output}"; then
    echo "PASS [${scope}] ${name}: denied by policy"
    passed=$((passed + 1))
    return
  fi

  if (( rc == 0 )); then
    echo "FAIL [${scope}] ${name}: command succeeded unexpectedly"
    echo "${output}"
    failed=$((failed + 1))
    return
  fi

  if grep -Eiq "not an openstack command|unknown command|endpoint.*not found|no service catalog|service .* not found|public endpoint|is not enabled" <<<"${output}"; then
    echo "SKIP [${scope}] ${name}: service/command unavailable"
    skipped=$((skipped + 1))
    return
  fi

  if grep -Eiq "not found|could not find|unable to locate|No .* with a name or ID|Bad Request|HTTP 400|Invalid|No Network|No Image|No Flavor" <<<"${output}"; then
    echo "INCONCLUSIVE [${scope}] ${name}: request failed before a clear policy denial"
    echo "${output}"
    inconclusive=$((inconclusive + 1))
    return
  fi

  echo "INCONCLUSIVE [${scope}] ${name}: unexpected failure"
  echo "${output}"
  inconclusive=$((inconclusive + 1))
}

echo "Running non-destructive mutation denial probes."
echo "A PASS means the service returned a policy denial. INCONCLUSIVE means validation/not-found happened before a clear policy decision."

run_denial_probe project "${PROJECT_RC}" "server create with invalid refs" \
  openstack server create --flavor "${PROBE_ID}" --image "${PROBE_ID}" --network "${PROBE_ID}" "${PROBE_NAME}"
run_denial_probe project "${PROJECT_RC}" "server delete nonexistent" \
  openstack server delete "${PROBE_ID}"
run_denial_probe project "${PROJECT_RC}" "network create" \
  openstack network create --provider-network-type "ai-observer-invalid-type" "${PROBE_NAME}"
run_denial_probe project "${PROJECT_RC}" "network delete nonexistent" \
  openstack network delete "${PROBE_ID}"
run_denial_probe project "${PROJECT_RC}" "volume create" \
  openstack volume create --size 0 "${PROBE_NAME}"
run_denial_probe project "${PROJECT_RC}" "volume delete nonexistent" \
  openstack volume delete "${PROBE_ID}"
run_denial_probe project "${PROJECT_RC}" "image set nonexistent" \
  openstack image set --name "${PROBE_NAME}" "${PROBE_ID}"
run_denial_probe project "${PROJECT_RC}" "loadbalancer create invalid subnet" \
  openstack loadbalancer create --name "${PROBE_NAME}" --vip-subnet-id "${PROBE_ID}"
run_denial_probe project "${PROJECT_RC}" "loadbalancer delete nonexistent" \
  openstack loadbalancer delete "${PROBE_ID}"

run_denial_probe system "${SYSTEM_RC}" "server delete nonexistent" \
  openstack server delete "${PROBE_ID}"
run_denial_probe system "${SYSTEM_RC}" "volume delete nonexistent" \
  openstack volume delete "${PROBE_ID}"

echo "Mutation denial summary: ${passed} denied, ${skipped} skipped, ${inconclusive} inconclusive, ${failed} failed."

if (( failed > 0 )); then
  exit 1
fi

if (( inconclusive > 0 )); then
  exit 2
fi
