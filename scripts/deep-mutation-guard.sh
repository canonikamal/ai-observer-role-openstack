#!/usr/bin/env bash
set -u

usage() {
  cat <<'EOF'
Usage:
  deep-mutation-guard.sh --admin-rc <admin-rc> [options]

Options:
  --prefix <prefix>       Resource name prefix. Default: ai-observer-deep.
  --volume-size <size>    Cinder test volume size in GiB. Default: 1.
  --skip-octavia          Do not run Octavia load balancer probes.
  --keep-resources        Do not clean up the disposable project/resources.
  -h, --help              Show this help.

Run this only against a cloud where temporary test projects/resources are safe.
The script creates a disposable project, AI test user, non-AI member test user,
AI project-scoped RC, AI system-scoped RC, member scoped RC, fixture scoped RC,
and valid image/flavor/network/subnet fixtures. It then attempts create, update,
and delete operations with the AI user's ai_observer role and with the non-AI
member role. Every AI mutation probe must be denied by policy, and normal member
mutations must remain allowed.
EOF
}

ADMIN_RC=""
PREFIX="ai-observer-deep"
VOLUME_SIZE="1"
SKIP_OCTAVIA="no"
KEEP_RESOURCES="no"
CUSTOM_ROLE="ai_observer"
IMPLIED_ROLE="reader"

while (( $# > 0 )); do
  case "$1" in
    --admin-rc)
      ADMIN_RC="${2:-}"
      shift 2
      ;;
    --prefix)
      PREFIX="${2:-}"
      shift 2
      ;;
    --volume-size)
      VOLUME_SIZE="${2:-}"
      shift 2
      ;;
    --skip-octavia)
      SKIP_OCTAVIA="yes"
      shift
      ;;
    --keep-resources)
      KEEP_RESOURCES="yes"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

if [[ -z "${ADMIN_RC}" ]]; then
  usage
  exit 2
fi

if [[ ! -r "${ADMIN_RC}" ]]; then
  echo "ERROR: cannot read admin RC: ${ADMIN_RC}"
  exit 2
fi

RUN_ID="$(date +%Y%m%d%H%M%S)-$$"
BASE="${PREFIX}-${RUN_ID}"
PROJECT_NAME="${BASE}-project"
USER_NAME="${BASE}-user"
USER_PASSWORD="${BASE}-password"
MEMBER_USER_NAME="${BASE}-member-user"
MEMBER_USER_PASSWORD="${BASE}-member-password"
KEYSTONE_DELETE_PROJECT_NAME="${BASE}-delete-project"
KEYSTONE_DELETE_USER_NAME="${BASE}-delete-user"
KEYSTONE_DELETE_USER_PASSWORD="${BASE}-delete-password"
FLAVOR_NAME="${BASE}-flavor"
IMAGE_NAME="${BASE}-image"
NETWORK_NAME="${BASE}-net"
SUBNET_NAME="${BASE}-subnet"
SUBNET_CIDR="192.0.2.0/24"

AI_RC_FILE="$(mktemp "/tmp/${BASE}-ai-openrc.XXXXXX")"
AI_SYSTEM_RC_FILE="$(mktemp "/tmp/${BASE}-ai-system-openrc.XXXXXX")"
MEMBER_RC_FILE="$(mktemp "/tmp/${BASE}-member-openrc.XXXXXX")"
FIXTURE_RC_FILE="$(mktemp "/tmp/${BASE}-fixture-openrc.XXXXXX")"
LOCAL_WORK_DIR="$(mktemp -d "${BASE}-local.XXXXXX")"
IMAGE_FILE="${LOCAL_WORK_DIR}/${BASE}-image.raw"
printf 'ai observer deep mutation guard\n' > "${IMAGE_FILE}"
chmod 600 "${AI_RC_FILE}" "${AI_SYSTEM_RC_FILE}" "${MEMBER_RC_FILE}" "${FIXTURE_RC_FILE}"
chmod 755 "${LOCAL_WORK_DIR}"
chmod 644 "${IMAGE_FILE}"
log_image_seed="Local image seed file: ${IMAGE_FILE}"

PROJECT_ID=""
USER_ID=""
MEMBER_USER_ID=""
KEYSTONE_DELETE_PROJECT_ID=""
KEYSTONE_DELETE_USER_ID=""
FLAVOR_ID=""
IMAGE_ID=""
NETWORK_ID=""
SUBNET_ID=""
ADMIN_ROLE=""
MEMBER_ROLE=""
ADMIN_USERNAME=""
ADMIN_USER_DOMAIN=""
ADMIN_USER_DOMAIN_ID=""
PROJECT_DOMAIN=""
PROJECT_DOMAIN_ID=""
USER_DOMAIN=""
USER_DOMAIN_ID=""
AUTH_URL=""
OCTAVIA_FIXTURE_ROLE=""

NOVA_CREATE_SERVER="${BASE}-nova-create"
NOVA_UPDATE_SERVER="${BASE}-nova-update"
NOVA_DELETE_SERVER="${BASE}-nova-delete"
NEUTRON_CREATE_NETWORK="${BASE}-net-create"
NEUTRON_UPDATE_NETWORK="${BASE}-net-update"
NEUTRON_DELETE_NETWORK="${BASE}-net-delete"
CINDER_CREATE_VOLUME="${BASE}-vol-create"
CINDER_UPDATE_VOLUME="${BASE}-vol-update"
CINDER_DELETE_VOLUME="${BASE}-vol-delete"
GLANCE_CREATE_IMAGE="${BASE}-img-create"
GLANCE_UPDATE_IMAGE="${BASE}-img-update"
GLANCE_DELETE_IMAGE="${BASE}-img-delete"
OCTAVIA_CREATE_LB="${BASE}-lb-create"
OCTAVIA_UPDATE_LB="${BASE}-lb-update"
OCTAVIA_DELETE_LB="${BASE}-lb-delete"
MEMBER_NOVA_SERVER="${BASE}-member-nova"
MEMBER_NEUTRON_NETWORK="${BASE}-member-net"
MEMBER_CINDER_VOLUME="${BASE}-member-vol"
MEMBER_GLANCE_IMAGE="${BASE}-member-img"
MEMBER_OCTAVIA_LB="${BASE}-member-lb"
SYSTEM_CREATE_ROLE="${BASE}-system-role-create"
SYSTEM_CREATE_FLAVOR="${BASE}-system-flavor-create"
SYSTEM_CREATE_VOLUME_TYPE="${BASE}-system-volume-type-create"

passed=0
skipped=0
failed=0
inconclusive=0

run_with_rc() {
  local rc_file="$1"
  shift
  RUN_OUTPUT="$(bash -c 'source "$1"; shift; "$@"' _ "${rc_file}" "$@" 2>&1)"
  RUN_STATUS=$?
}

run_admin() {
  run_with_rc "${ADMIN_RC}" "$@"
}

run_ai() {
  run_with_rc "${AI_RC_FILE}" "$@"
}

run_ai_system() {
  run_with_rc "${AI_SYSTEM_RC_FILE}" "$@"
}

run_member() {
  run_with_rc "${MEMBER_RC_FILE}" "$@"
}

run_fixture() {
  run_with_rc "${FIXTURE_RC_FILE}" "$@"
}

admin_env() {
  bash -c 'source "$1"; printenv "$2" 2>/dev/null || true' _ "${ADMIN_RC}" "$1"
}

write_export() {
  local file="$1"
  local name="$2"
  local value="$3"
  if [[ -n "${value}" ]]; then
    printf 'export %s=%q\n' "${name}" "${value}" >> "${file}"
  fi
}

write_unset() {
  local file="$1"
  shift
  local name
  for name in "$@"; do
    printf 'unset %s\n' "${name}" >> "${file}"
  done
}

write_password_auth_safety() {
  local file="$1"
  write_export "${file}" OS_AUTH_TYPE "password"
  write_unset "${file}" \
    OS_TOKEN \
    OS_APPLICATION_CREDENTIAL_ID \
    OS_APPLICATION_CREDENTIAL_NAME \
    OS_APPLICATION_CREDENTIAL_SECRET \
    OS_ACCESS_KEY \
    OS_SECRET_KEY \
    OS_TRUST_ID
}

is_policy_denied() {
  grep -Eiq "policy doesn't allow|disallowed by policy|forbidden|not authorized|HttpException: 403|HTTP 403|status code: 403|403 Forbidden" <<<"$1"
}

is_unavailable() {
  grep -Eiq "not an openstack command|unknown command|endpoint.*not found|no service catalog|service .* not found|public endpoint|is not enabled" <<<"$1"
}

is_absent() {
  grep -Eiq "No .* found|not found|does not exist|No .* with a name or ID|Unable to find|Unable to locate|Could not find" <<<"$1"
}

record_pass() {
  echo "PASS $1"
  passed=$((passed + 1))
}

record_skip() {
  echo "SKIP $1"
  echo "$2"
  skipped=$((skipped + 1))
}

record_fail() {
  echo "FAIL $1"
  echo "$2"
  failed=$((failed + 1))
}

record_inconclusive() {
  echo "INCONCLUSIVE $1"
  echo "$2"
  inconclusive=$((inconclusive + 1))
}

die_setup() {
  echo "ERROR: $1"
  if [[ -n "${2:-}" ]]; then
    echo "$2"
  fi
  exit 2
}

require_admin() {
  local description="$1"
  shift
  run_admin "$@"
  if (( RUN_STATUS != 0 )); then
    die_setup "${description} failed" "${RUN_OUTPUT}"
  fi
}

require_fixture() {
  local description="$1"
  shift
  run_fixture "$@"
  if (( RUN_STATUS != 0 )); then
    die_setup "${description} failed" "${RUN_OUTPUT}"
  fi
}

log_created() {
  local type="$1"
  local name="$2"
  local id="$3"
  if [[ -n "${id}" ]]; then
    echo "CREATED ${type}: ${name} (${id})"
  else
    echo "CREATED ${type}: ${name}"
  fi
}

first_output_value() {
  local output="$1"
  local value
  value="$(grep -Eim1 '^[[:space:]]*[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[[:space:]]*$' <<<"${output}" | tr -d '[:space:]')"
  if [[ -z "${value}" ]]; then
    value="$(grep -Eim1 '^[[:space:]]*[0-9a-f]{32}[[:space:]]*$' <<<"${output}" | tr -d '[:space:]')"
  fi
  if [[ -z "${value}" ]]; then
    value="$(sed -n '/[^[:space:]]/{s/^[[:space:]]*//;s/[[:space:]]*$//;p;q;}' <<<"${output}")"
  fi
  printf '%s' "${value}"
}

cleanup_one() {
  local rc_file="$1"
  local description="$2"
  shift
  shift
  echo "CLEANUP ${description}"
  run_with_rc "${rc_file}" "$@"
  if (( RUN_STATUS == 0 )); then
    echo "CLEANUP OK ${description}"
  elif is_absent "${RUN_OUTPUT}"; then
    echo "CLEANUP OK ${description}: already absent"
  elif is_unavailable "${RUN_OUTPUT}"; then
    echo "CLEANUP SKIP ${description}: service/command unavailable"
  else
    echo "CLEANUP WARN ${description}"
    echo "${RUN_OUTPUT}"
  fi
}

cleanup() {
  if [[ "${KEEP_RESOURCES}" == "yes" ]]; then
    echo
    echo "Keeping disposable resources because --keep-resources was requested."
    echo "Project: ${PROJECT_NAME} ${PROJECT_ID}"
    echo "AI project RC: ${AI_RC_FILE}"
    echo "AI system RC: ${AI_SYSTEM_RC_FILE}"
    echo "Member RC: ${MEMBER_RC_FILE}"
    echo "Fixture RC: ${FIXTURE_RC_FILE}"
    return
  fi

  echo
  echo "Cleaning up disposable resources..."

  if [[ -n "${SUBNET_ID}" && "${SKIP_OCTAVIA}" != "yes" ]]; then
    cleanup_one "${ADMIN_RC}" "Octavia create-probe load balancer ${OCTAVIA_CREATE_LB}" openstack loadbalancer delete --cascade --wait "${OCTAVIA_CREATE_LB}"
    cleanup_one "${ADMIN_RC}" "Octavia update fixture load balancer ${OCTAVIA_UPDATE_LB}" openstack loadbalancer delete --cascade --wait "${OCTAVIA_UPDATE_LB}"
    cleanup_one "${ADMIN_RC}" "Octavia delete fixture load balancer ${OCTAVIA_DELETE_LB}" openstack loadbalancer delete --cascade --wait "${OCTAVIA_DELETE_LB}"
  fi

  cleanup_one "${FIXTURE_RC_FILE}" "Nova create-probe server ${NOVA_CREATE_SERVER}" openstack server delete --wait "${NOVA_CREATE_SERVER}"
  cleanup_one "${FIXTURE_RC_FILE}" "Nova update fixture server ${NOVA_UPDATE_SERVER}" openstack server delete --wait "${NOVA_UPDATE_SERVER}"
  cleanup_one "${FIXTURE_RC_FILE}" "Nova delete fixture server ${NOVA_DELETE_SERVER}" openstack server delete --wait "${NOVA_DELETE_SERVER}"
  cleanup_one "${FIXTURE_RC_FILE}" "Cinder create-probe volume ${CINDER_CREATE_VOLUME}" openstack volume delete "${CINDER_CREATE_VOLUME}"
  cleanup_one "${FIXTURE_RC_FILE}" "Cinder update fixture volume ${CINDER_UPDATE_VOLUME}" openstack volume delete "${CINDER_UPDATE_VOLUME}"
  cleanup_one "${FIXTURE_RC_FILE}" "Cinder delete fixture volume ${CINDER_DELETE_VOLUME}" openstack volume delete "${CINDER_DELETE_VOLUME}"
  cleanup_one "${FIXTURE_RC_FILE}" "Glance create-probe image ${GLANCE_CREATE_IMAGE}" openstack image delete "${GLANCE_CREATE_IMAGE}"
  cleanup_one "${FIXTURE_RC_FILE}" "Glance update fixture image ${GLANCE_UPDATE_IMAGE}" openstack image delete "${GLANCE_UPDATE_IMAGE}"
  cleanup_one "${FIXTURE_RC_FILE}" "Glance delete fixture image ${GLANCE_DELETE_IMAGE}" openstack image delete "${GLANCE_DELETE_IMAGE}"
  cleanup_one "${FIXTURE_RC_FILE}" "Neutron create-probe network ${NEUTRON_CREATE_NETWORK}" openstack network delete "${NEUTRON_CREATE_NETWORK}"
  cleanup_one "${FIXTURE_RC_FILE}" "Neutron update fixture network ${NEUTRON_UPDATE_NETWORK}" openstack network delete "${NEUTRON_UPDATE_NETWORK}"
  cleanup_one "${FIXTURE_RC_FILE}" "Neutron delete fixture network ${NEUTRON_DELETE_NETWORK}" openstack network delete "${NEUTRON_DELETE_NETWORK}"
  cleanup_one "${FIXTURE_RC_FILE}" "member-regression server ${MEMBER_NOVA_SERVER}" openstack server delete --wait "${MEMBER_NOVA_SERVER}"
  cleanup_one "${FIXTURE_RC_FILE}" "member-regression volume ${MEMBER_CINDER_VOLUME}" openstack volume delete "${MEMBER_CINDER_VOLUME}"
  cleanup_one "${FIXTURE_RC_FILE}" "member-regression image ${MEMBER_GLANCE_IMAGE}" openstack image delete "${MEMBER_GLANCE_IMAGE}"
  cleanup_one "${FIXTURE_RC_FILE}" "member-regression network ${MEMBER_NEUTRON_NETWORK}" openstack network delete "${MEMBER_NEUTRON_NETWORK}"
  if [[ "${SKIP_OCTAVIA}" != "yes" ]]; then
    cleanup_one "${ADMIN_RC}" "member-regression load balancer ${MEMBER_OCTAVIA_LB}" openstack loadbalancer delete --cascade --wait "${MEMBER_OCTAVIA_LB}"
  fi
  if [[ -n "${SUBNET_ID}" ]]; then
    cleanup_one "${FIXTURE_RC_FILE}" "base subnet ${SUBNET_NAME} ${SUBNET_ID}" openstack subnet delete "${SUBNET_ID}"
  fi
  if [[ -n "${NETWORK_ID}" ]]; then
    cleanup_one "${FIXTURE_RC_FILE}" "base network ${NETWORK_NAME} ${NETWORK_ID}" openstack network delete "${NETWORK_ID}"
  fi
  if [[ -n "${IMAGE_ID}" ]]; then
    cleanup_one "${ADMIN_RC}" "base image ${IMAGE_NAME} ${IMAGE_ID}" openstack image delete "${IMAGE_ID}"
  fi
  if [[ -n "${FLAVOR_ID}" ]]; then
    cleanup_one "${ADMIN_RC}" "base flavor ${FLAVOR_NAME} ${FLAVOR_ID}" openstack flavor delete "${FLAVOR_ID}"
  fi
  cleanup_one "${ADMIN_RC}" "system-scope create-probe flavor ${SYSTEM_CREATE_FLAVOR}" openstack flavor delete "${SYSTEM_CREATE_FLAVOR}"
  cleanup_one "${ADMIN_RC}" "system-scope create-probe volume type ${SYSTEM_CREATE_VOLUME_TYPE}" openstack volume type delete "${SYSTEM_CREATE_VOLUME_TYPE}"
  cleanup_one "${ADMIN_RC}" "system-scope create-probe role ${SYSTEM_CREATE_ROLE}" openstack role delete "${SYSTEM_CREATE_ROLE}"
  if [[ -n "${KEYSTONE_DELETE_USER_ID}" ]]; then
    cleanup_one "${ADMIN_RC}" "system-scope delete fixture user ${KEYSTONE_DELETE_USER_NAME} ${KEYSTONE_DELETE_USER_ID}" openstack user delete "${KEYSTONE_DELETE_USER_ID}"
  fi
  if [[ -n "${KEYSTONE_DELETE_PROJECT_ID}" ]]; then
    cleanup_one "${ADMIN_RC}" "system-scope delete fixture project ${KEYSTONE_DELETE_PROJECT_NAME} ${KEYSTONE_DELETE_PROJECT_ID}" openstack project delete "${KEYSTONE_DELETE_PROJECT_ID}"
  fi
  if [[ -n "${USER_ID}" ]]; then
    cleanup_one "${ADMIN_RC}" "test user ${USER_NAME} ${USER_ID}" openstack user delete "${USER_ID}"
  fi
  if [[ -n "${MEMBER_USER_ID}" ]]; then
    cleanup_one "${ADMIN_RC}" "member regression user ${MEMBER_USER_NAME} ${MEMBER_USER_ID}" openstack user delete "${MEMBER_USER_ID}"
  fi
  if [[ -n "${PROJECT_ID}" ]]; then
    cleanup_one "${ADMIN_RC}" "test project ${PROJECT_NAME} ${PROJECT_ID}" openstack project delete "${PROJECT_ID}"
  fi
  echo "CLEANUP local temp files: ${AI_RC_FILE}, ${AI_SYSTEM_RC_FILE}, ${MEMBER_RC_FILE}, ${FIXTURE_RC_FILE}, ${LOCAL_WORK_DIR}"
  rm -f "${AI_RC_FILE}" "${AI_SYSTEM_RC_FILE}" "${MEMBER_RC_FILE}" "${FIXTURE_RC_FILE}"
  rm -rf "${LOCAL_WORK_DIR}"
  echo "CLEANUP OK local temp files"
}
trap cleanup EXIT

classify_ai_mutation() {
  local name="$1"
  local output="$2"
  local status="$3"

  if is_policy_denied "${output}"; then
    record_pass "${name}: denied by policy"
  elif (( status == 0 )); then
    record_fail "${name}: AI user unexpectedly performed mutation" "${output}"
  elif is_unavailable "${output}"; then
    record_skip "${name}: service/command unavailable" "${output}"
  else
    record_fail "${name}: request was not denied by policy" "${output}"
  fi
}

classify_ai_create() {
  local name="$1"
  local resource_name="$2"
  local output="$3"
  local status="$4"
  shift 4

  if is_policy_denied "${output}"; then
    record_pass "${name}: denied by policy"
  elif (( status == 0 )); then
    record_fail "${name}: AI user unexpectedly created resource" "${output}"
  elif is_unavailable "${output}"; then
    record_skip "${name}: service/command unavailable" "${output}"
  else
    run_fixture openstack "$@" "${resource_name}"
    if (( RUN_STATUS == 0 )); then
      record_fail "${name}: resource exists after failed AI create command" "${output}"
    else
      record_fail "${name}: request was not denied by policy" "${output}"
    fi
  fi
}

classify_allowed_mutation() {
  local name="$1"
  local output="$2"
  local status="$3"

  if (( status == 0 )); then
    record_pass "${name}: allowed for non-AI role"
  elif is_policy_denied "${output}"; then
    record_fail "${name}: unexpectedly denied by policy" "${output}"
  elif is_unavailable "${output}"; then
    record_skip "${name}: service/command unavailable" "${output}"
  else
    record_pass "${name}: not denied by policy; service returned non-policy error"
    echo "${output}"
  fi
}

create_fixture() {
  local description="$1"
  local resource_type="$2"
  local resource_name="$3"
  shift
  shift
  shift
  run_fixture "$@"
  if (( RUN_STATUS == 0 )); then
    log_created "${resource_type}" "${resource_name}" "$(first_output_value "${RUN_OUTPUT}")"
    return 0
  fi
  if is_unavailable "${RUN_OUTPUT}"; then
    record_skip "${description}: service/command unavailable" "${RUN_OUTPUT}"
    return 1
  fi
  record_inconclusive "${description}: fixture creation failed" "${RUN_OUTPUT}"
  return 1
}

preflight_ai_visibility() {
  local name="$1"
  shift
  run_ai "$@"
  if (( RUN_STATUS == 0 )); then
    echo "PASS preflight: AI can see ${name}"
    return
  fi
  die_setup "AI user cannot see ${name}; mutation probes would fail before policy enforcement" "${RUN_OUTPUT}"
}

echo "Running self-contained deep mutation guard."
echo "Use only where temporary projects/resources are safe."
echo "Resource prefix: ${BASE}"
echo "${log_image_seed}"
echo

AUTH_URL="$(admin_env OS_AUTH_URL)"
ADMIN_USERNAME="$(admin_env OS_USERNAME)"
ADMIN_USER_DOMAIN="$(admin_env OS_USER_DOMAIN_NAME)"
ADMIN_USER_DOMAIN_ID="$(admin_env OS_USER_DOMAIN_ID)"
PROJECT_DOMAIN="$(admin_env OS_PROJECT_DOMAIN_NAME)"
PROJECT_DOMAIN_ID="$(admin_env OS_PROJECT_DOMAIN_ID)"
USER_DOMAIN="$(admin_env OS_USER_DOMAIN_NAME)"
USER_DOMAIN_ID="$(admin_env OS_USER_DOMAIN_ID)"

if [[ -z "${AUTH_URL}" || -z "${ADMIN_USERNAME}" ]]; then
  die_setup "admin RC must export at least OS_AUTH_URL and OS_USERNAME"
fi
if [[ -z "${ADMIN_USER_DOMAIN}" ]]; then
  ADMIN_USER_DOMAIN="${ADMIN_USER_DOMAIN_ID:-Default}"
fi
if [[ -z "${PROJECT_DOMAIN}" ]]; then
  PROJECT_DOMAIN="${PROJECT_DOMAIN_ID:-Default}"
fi
if [[ -z "${USER_DOMAIN}" ]]; then
  USER_DOMAIN="${USER_DOMAIN_ID:-Default}"
fi

echo "== Preflight =="
require_admin "admin token issue" openstack token issue
require_admin "custom role lookup" openstack role show "${CUSTOM_ROLE}"
require_admin "reader role lookup" openstack role show "${IMPLIED_ROLE}"
run_admin openstack implied role list -f value
if (( RUN_STATUS != 0 )) || ! grep -Eq "${CUSTOM_ROLE}.*${IMPLIED_ROLE}|${IMPLIED_ROLE}.*${CUSTOM_ROLE}" <<<"${RUN_OUTPUT}"; then
  die_setup "could not verify ${CUSTOM_ROLE} implies ${IMPLIED_ROLE}" "${RUN_OUTPUT}"
fi
run_admin openstack role show admin -f value -c name
if (( RUN_STATUS == 0 )); then
  ADMIN_ROLE="admin"
else
  require_admin "admin role lookup" openstack role show Admin
  ADMIN_ROLE="Admin"
fi
run_admin openstack role show member -f value -c name
if (( RUN_STATUS == 0 )); then
  MEMBER_ROLE="member"
else
  require_admin "member role lookup" openstack role show Member
  MEMBER_ROLE="Member"
fi
echo "PASS preflight: roles are present and ${CUSTOM_ROLE} implies ${IMPLIED_ROLE}"

echo
echo "== Disposable project and user setup =="
require_admin "project create" openstack project create --domain "${PROJECT_DOMAIN}" -f value -c id "${PROJECT_NAME}"
PROJECT_ID="$(head -n 1 <<<"${RUN_OUTPUT}")"
log_created "test project" "${PROJECT_NAME}" "${PROJECT_ID}"
require_admin "user create" openstack user create --domain "${USER_DOMAIN}" --password "${USER_PASSWORD}" -f value -c id "${USER_NAME}"
USER_ID="$(head -n 1 <<<"${RUN_OUTPUT}")"
log_created "test user" "${USER_NAME}" "${USER_ID}"
require_admin "member regression user create" openstack user create --domain "${USER_DOMAIN}" --password "${MEMBER_USER_PASSWORD}" -f value -c id "${MEMBER_USER_NAME}"
MEMBER_USER_ID="$(head -n 1 <<<"${RUN_OUTPUT}")"
log_created "member regression user" "${MEMBER_USER_NAME}" "${MEMBER_USER_ID}"
require_admin "system delete fixture project create" openstack project create --domain "${PROJECT_DOMAIN}" -f value -c id "${KEYSTONE_DELETE_PROJECT_NAME}"
KEYSTONE_DELETE_PROJECT_ID="$(head -n 1 <<<"${RUN_OUTPUT}")"
log_created "system-scope delete fixture project" "${KEYSTONE_DELETE_PROJECT_NAME}" "${KEYSTONE_DELETE_PROJECT_ID}"
require_admin "system delete fixture user create" openstack user create --domain "${USER_DOMAIN}" --password "${KEYSTONE_DELETE_USER_PASSWORD}" -f value -c id "${KEYSTONE_DELETE_USER_NAME}"
KEYSTONE_DELETE_USER_ID="$(head -n 1 <<<"${RUN_OUTPUT}")"
log_created "system-scope delete fixture user" "${KEYSTONE_DELETE_USER_NAME}" "${KEYSTONE_DELETE_USER_ID}"
require_admin "grant ${CUSTOM_ROLE} on project" openstack role add --user "${USER_ID}" --project "${PROJECT_ID}" "${CUSTOM_ROLE}"
require_admin "grant ${CUSTOM_ROLE} on system" openstack role add --user "${USER_ID}" --system all "${CUSTOM_ROLE}"
require_admin "grant ${MEMBER_ROLE} to member regression user on project" openstack role add --user "${MEMBER_USER_ID}" --project "${PROJECT_ID}" "${MEMBER_ROLE}"
require_admin "grant ${ADMIN_ROLE} to admin user on test project" openstack role add --user "${ADMIN_USERNAME}" --user-domain "${ADMIN_USER_DOMAIN}" --project "${PROJECT_ID}" "${ADMIN_ROLE}"
if [[ "${SKIP_OCTAVIA}" != "yes" ]]; then
  for candidate_role in load-balancer_member load-balancer_admin; do
    run_admin openstack role show "${candidate_role}"
    if (( RUN_STATUS == 0 )); then
      OCTAVIA_FIXTURE_ROLE="${candidate_role}"
      require_admin "grant ${candidate_role} to admin user on test project" openstack role add --user "${ADMIN_USERNAME}" --user-domain "${ADMIN_USER_DOMAIN}" --project "${PROJECT_ID}" "${candidate_role}"
      require_admin "grant ${candidate_role} to member regression user on test project" openstack role add --user "${MEMBER_USER_ID}" --project "${PROJECT_ID}" "${candidate_role}"
      break
    fi
  done
fi
echo "GRANTED ${CUSTOM_ROLE} to ${USER_NAME} on project ${PROJECT_ID}"
echo "GRANTED ${CUSTOM_ROLE} to ${USER_NAME} on system all"
echo "GRANTED ${MEMBER_ROLE} to ${MEMBER_USER_NAME} on project ${PROJECT_ID} for non-AI role regression"
echo "GRANTED ${ADMIN_ROLE} to ${ADMIN_USERNAME} on project ${PROJECT_ID} for fixture setup"
if [[ -n "${OCTAVIA_FIXTURE_ROLE}" ]]; then
  echo "GRANTED ${OCTAVIA_FIXTURE_ROLE} to ${ADMIN_USERNAME} on project ${PROJECT_ID} for Octavia fixture setup"
  echo "GRANTED ${OCTAVIA_FIXTURE_ROLE} to ${MEMBER_USER_NAME} on project ${PROJECT_ID} for Octavia non-AI role regression"
elif [[ "${SKIP_OCTAVIA}" != "yes" ]]; then
  echo "INFO no load-balancer_member/load-balancer_admin role found; Octavia fixtures will use the normal fixture admin scope"
fi
echo "Project: ${PROJECT_NAME} ${PROJECT_ID}"
echo "User: ${USER_NAME} ${USER_ID}"
echo "Member regression user: ${MEMBER_USER_NAME} ${MEMBER_USER_ID}"

write_export "${AI_RC_FILE}" OS_AUTH_URL "${AUTH_URL}"
write_export "${AI_RC_FILE}" OS_USERNAME "${USER_NAME}"
write_export "${AI_RC_FILE}" OS_PASSWORD "${USER_PASSWORD}"
write_export "${AI_RC_FILE}" OS_USER_DOMAIN_NAME "${USER_DOMAIN}"
write_export "${AI_RC_FILE}" OS_PROJECT_ID "${PROJECT_ID}"
write_export "${AI_RC_FILE}" OS_IDENTITY_API_VERSION "$(admin_env OS_IDENTITY_API_VERSION)"
write_export "${AI_RC_FILE}" OS_INTERFACE "$(admin_env OS_INTERFACE)"
write_export "${AI_RC_FILE}" OS_REGION_NAME "$(admin_env OS_REGION_NAME)"
write_export "${AI_RC_FILE}" OS_CACERT "$(admin_env OS_CACERT)"
write_export "${AI_RC_FILE}" OS_INSECURE "$(admin_env OS_INSECURE)"
write_password_auth_safety "${AI_RC_FILE}"
write_unset "${AI_RC_FILE}" OS_SYSTEM_SCOPE OS_PROJECT_NAME OS_PROJECT_DOMAIN_NAME OS_PROJECT_DOMAIN_ID OS_TENANT_NAME OS_TENANT_ID OS_DOMAIN_NAME OS_DOMAIN_ID

write_export "${AI_SYSTEM_RC_FILE}" OS_AUTH_URL "${AUTH_URL}"
write_export "${AI_SYSTEM_RC_FILE}" OS_USERNAME "${USER_NAME}"
write_export "${AI_SYSTEM_RC_FILE}" OS_PASSWORD "${USER_PASSWORD}"
write_export "${AI_SYSTEM_RC_FILE}" OS_USER_DOMAIN_NAME "${USER_DOMAIN}"
write_export "${AI_SYSTEM_RC_FILE}" OS_SYSTEM_SCOPE "all"
write_export "${AI_SYSTEM_RC_FILE}" OS_IDENTITY_API_VERSION "$(admin_env OS_IDENTITY_API_VERSION)"
write_export "${AI_SYSTEM_RC_FILE}" OS_INTERFACE "$(admin_env OS_INTERFACE)"
write_export "${AI_SYSTEM_RC_FILE}" OS_REGION_NAME "$(admin_env OS_REGION_NAME)"
write_export "${AI_SYSTEM_RC_FILE}" OS_CACERT "$(admin_env OS_CACERT)"
write_export "${AI_SYSTEM_RC_FILE}" OS_INSECURE "$(admin_env OS_INSECURE)"
write_password_auth_safety "${AI_SYSTEM_RC_FILE}"
write_unset "${AI_SYSTEM_RC_FILE}" OS_PROJECT_ID OS_PROJECT_NAME OS_PROJECT_DOMAIN_NAME OS_PROJECT_DOMAIN_ID OS_TENANT_NAME OS_TENANT_ID OS_DOMAIN_NAME OS_DOMAIN_ID

write_export "${MEMBER_RC_FILE}" OS_AUTH_URL "${AUTH_URL}"
write_export "${MEMBER_RC_FILE}" OS_USERNAME "${MEMBER_USER_NAME}"
write_export "${MEMBER_RC_FILE}" OS_PASSWORD "${MEMBER_USER_PASSWORD}"
write_export "${MEMBER_RC_FILE}" OS_USER_DOMAIN_NAME "${USER_DOMAIN}"
write_export "${MEMBER_RC_FILE}" OS_PROJECT_ID "${PROJECT_ID}"
write_export "${MEMBER_RC_FILE}" OS_IDENTITY_API_VERSION "$(admin_env OS_IDENTITY_API_VERSION)"
write_export "${MEMBER_RC_FILE}" OS_INTERFACE "$(admin_env OS_INTERFACE)"
write_export "${MEMBER_RC_FILE}" OS_REGION_NAME "$(admin_env OS_REGION_NAME)"
write_export "${MEMBER_RC_FILE}" OS_CACERT "$(admin_env OS_CACERT)"
write_export "${MEMBER_RC_FILE}" OS_INSECURE "$(admin_env OS_INSECURE)"
write_password_auth_safety "${MEMBER_RC_FILE}"
write_unset "${MEMBER_RC_FILE}" OS_SYSTEM_SCOPE OS_PROJECT_NAME OS_PROJECT_DOMAIN_NAME OS_PROJECT_DOMAIN_ID OS_TENANT_NAME OS_TENANT_ID OS_DOMAIN_NAME OS_DOMAIN_ID

cp "${ADMIN_RC}" "${FIXTURE_RC_FILE}"
{
  printf '\nexport OS_PROJECT_ID=%q\n' "${PROJECT_ID}"
  printf 'unset OS_PROJECT_NAME\n'
  printf 'unset OS_PROJECT_DOMAIN_NAME\n'
  printf 'unset OS_SYSTEM_SCOPE\n'
} >> "${FIXTURE_RC_FILE}"
log_created "AI project RC file" "${AI_RC_FILE}" ""
log_created "AI system RC file" "${AI_SYSTEM_RC_FILE}" ""
log_created "member regression RC file" "${MEMBER_RC_FILE}" ""
log_created "fixture RC file" "${FIXTURE_RC_FILE}" ""

require_fixture "fixture token issue" openstack token issue
run_ai openstack token issue
if (( RUN_STATUS != 0 )); then
  die_setup "AI project token issue failed" "${RUN_OUTPUT}"
fi
run_ai_system openstack token issue
if (( RUN_STATUS != 0 )); then
  die_setup "AI system token issue failed" "${RUN_OUTPUT}"
fi
run_member openstack token issue
if (( RUN_STATUS != 0 )); then
  die_setup "member regression token issue failed" "${RUN_OUTPUT}"
fi

echo
echo "== Base fixture setup =="
require_admin "flavor create" openstack flavor create --ram 64 --disk 1 --vcpus 1 -f value -c id "${FLAVOR_NAME}"
FLAVOR_ID="$(head -n 1 <<<"${RUN_OUTPUT}")"
log_created "base flavor" "${FLAVOR_NAME}" "${FLAVOR_ID}"
if [[ ! -r "${IMAGE_FILE}" ]]; then
  die_setup "local image seed file is not readable: ${IMAGE_FILE}"
fi
require_admin "image create" openstack image create --disk-format raw --container-format bare --file "${IMAGE_FILE}" --public -f value -c id "${IMAGE_NAME}"
IMAGE_ID="$(head -n 1 <<<"${RUN_OUTPUT}")"
log_created "base image" "${IMAGE_NAME}" "${IMAGE_ID}"
require_fixture "network create" openstack network create -f value -c id "${NETWORK_NAME}"
NETWORK_ID="$(head -n 1 <<<"${RUN_OUTPUT}")"
log_created "base network" "${NETWORK_NAME}" "${NETWORK_ID}"
require_fixture "subnet create" openstack subnet create --network "${NETWORK_ID}" --subnet-range "${SUBNET_CIDR}" -f value -c id "${SUBNET_NAME}"
SUBNET_ID="$(head -n 1 <<<"${RUN_OUTPUT}")"
log_created "base subnet" "${SUBNET_NAME}" "${SUBNET_ID}"

preflight_ai_visibility "image ${IMAGE_ID}" openstack image show "${IMAGE_ID}"
preflight_ai_visibility "flavor ${FLAVOR_ID}" openstack flavor show "${FLAVOR_ID}"
preflight_ai_visibility "network ${NETWORK_ID}" openstack network show "${NETWORK_ID}"
preflight_ai_visibility "subnet ${SUBNET_ID}" openstack subnet show "${SUBNET_ID}"

echo
echo "== Non-AI member role regression: Nova =="
run_member openstack server create --flavor "${FLAVOR_ID}" --image "${IMAGE_ID}" --network "${NETWORK_ID}" -f value -c id "${MEMBER_NOVA_SERVER}"
classify_allowed_mutation "member nova server create" "${RUN_OUTPUT}" "${RUN_STATUS}"
if (( RUN_STATUS == 0 )); then
  run_member openstack server set --property ai_observer_guard=member-regression "${MEMBER_NOVA_SERVER}"
  classify_allowed_mutation "member nova server set" "${RUN_OUTPUT}" "${RUN_STATUS}"
  run_member openstack server delete --wait "${MEMBER_NOVA_SERVER}"
  classify_allowed_mutation "member nova server delete" "${RUN_OUTPUT}" "${RUN_STATUS}"
fi

echo
echo "== Non-AI member role regression: Neutron =="
run_member openstack network create -f value -c id "${MEMBER_NEUTRON_NETWORK}"
classify_allowed_mutation "member neutron network create" "${RUN_OUTPUT}" "${RUN_STATUS}"
if (( RUN_STATUS == 0 )); then
  run_member openstack network set --description "${BASE} member regression" "${MEMBER_NEUTRON_NETWORK}"
  classify_allowed_mutation "member neutron network set" "${RUN_OUTPUT}" "${RUN_STATUS}"
  run_member openstack network delete "${MEMBER_NEUTRON_NETWORK}"
  classify_allowed_mutation "member neutron network delete" "${RUN_OUTPUT}" "${RUN_STATUS}"
fi

echo
echo "== Non-AI member role regression: Cinder =="
run_member openstack volume create --size "${VOLUME_SIZE}" -f value -c id "${MEMBER_CINDER_VOLUME}"
classify_allowed_mutation "member cinder volume create" "${RUN_OUTPUT}" "${RUN_STATUS}"
if (( RUN_STATUS == 0 )); then
  run_member openstack volume set --description "${BASE} member regression" "${MEMBER_CINDER_VOLUME}"
  classify_allowed_mutation "member cinder volume set" "${RUN_OUTPUT}" "${RUN_STATUS}"
  run_member openstack volume delete "${MEMBER_CINDER_VOLUME}"
  classify_allowed_mutation "member cinder volume delete" "${RUN_OUTPUT}" "${RUN_STATUS}"
fi

echo
echo "== Non-AI member role regression: Glance =="
run_member openstack image create --disk-format raw --container-format bare --file "${IMAGE_FILE}" -f value -c id "${MEMBER_GLANCE_IMAGE}"
classify_allowed_mutation "member glance image create" "${RUN_OUTPUT}" "${RUN_STATUS}"
if (( RUN_STATUS == 0 )); then
  run_member openstack image set --tag ai-observer-guard "${MEMBER_GLANCE_IMAGE}"
  classify_allowed_mutation "member glance image set" "${RUN_OUTPUT}" "${RUN_STATUS}"
  run_member openstack image delete "${MEMBER_GLANCE_IMAGE}"
  classify_allowed_mutation "member glance image delete" "${RUN_OUTPUT}" "${RUN_STATUS}"
fi

if [[ "${SKIP_OCTAVIA}" != "yes" ]]; then
  echo
  echo "== Non-AI member role regression: Octavia =="
  if [[ -n "${OCTAVIA_FIXTURE_ROLE}" ]]; then
    run_member openstack loadbalancer create --name "${MEMBER_OCTAVIA_LB}" --vip-subnet-id "${SUBNET_ID}" --wait -f value -c id
    classify_allowed_mutation "member octavia loadbalancer create" "${RUN_OUTPUT}" "${RUN_STATUS}"
    if (( RUN_STATUS == 0 )); then
      run_member openstack loadbalancer set --description "${BASE} member regression" "${MEMBER_OCTAVIA_LB}"
      classify_allowed_mutation "member octavia loadbalancer set" "${RUN_OUTPUT}" "${RUN_STATUS}"
      run_member openstack loadbalancer delete --cascade --wait "${MEMBER_OCTAVIA_LB}"
      classify_allowed_mutation "member octavia loadbalancer delete" "${RUN_OUTPUT}" "${RUN_STATUS}"
    fi
  else
    record_skip "member octavia loadbalancer regression: no load-balancer_member/load-balancer_admin role available" ""
  fi
fi

echo
echo "== Nova create denial =="
run_ai openstack server create --flavor "${FLAVOR_ID}" --image "${IMAGE_ID}" --network "${NETWORK_ID}" "${NOVA_CREATE_SERVER}"
classify_ai_create "nova server create" "${NOVA_CREATE_SERVER}" "${RUN_OUTPUT}" "${RUN_STATUS}" server show

echo
echo "== Nova update denial =="
if create_fixture "nova server update fixture" "Nova update fixture server" "${NOVA_UPDATE_SERVER}" openstack server create --flavor "${FLAVOR_ID}" --image "${IMAGE_ID}" --network "${NETWORK_ID}" -f value -c id "${NOVA_UPDATE_SERVER}"; then
  run_ai openstack server set --name "${NOVA_UPDATE_SERVER}-renamed" "${NOVA_UPDATE_SERVER}"
  classify_ai_mutation "nova server set" "${RUN_OUTPUT}" "${RUN_STATUS}"
fi

echo
echo "== Nova delete denial =="
if create_fixture "nova server delete fixture" "Nova delete fixture server" "${NOVA_DELETE_SERVER}" openstack server create --flavor "${FLAVOR_ID}" --image "${IMAGE_ID}" --network "${NETWORK_ID}" -f value -c id "${NOVA_DELETE_SERVER}"; then
  run_ai openstack server delete "${NOVA_DELETE_SERVER}"
  classify_ai_mutation "nova server delete" "${RUN_OUTPUT}" "${RUN_STATUS}"
fi

echo
echo "== Neutron create denial =="
run_ai openstack network create "${NEUTRON_CREATE_NETWORK}"
classify_ai_create "neutron network create" "${NEUTRON_CREATE_NETWORK}" "${RUN_OUTPUT}" "${RUN_STATUS}" network show

echo
echo "== Neutron update denial =="
if create_fixture "neutron network update fixture" "Neutron update fixture network" "${NEUTRON_UPDATE_NETWORK}" openstack network create -f value -c id "${NEUTRON_UPDATE_NETWORK}"; then
  run_ai openstack network set --name "${NEUTRON_UPDATE_NETWORK}-renamed" "${NEUTRON_UPDATE_NETWORK}"
  classify_ai_mutation "neutron network set" "${RUN_OUTPUT}" "${RUN_STATUS}"
fi

echo
echo "== Neutron delete denial =="
if create_fixture "neutron network delete fixture" "Neutron delete fixture network" "${NEUTRON_DELETE_NETWORK}" openstack network create -f value -c id "${NEUTRON_DELETE_NETWORK}"; then
  run_ai openstack network delete "${NEUTRON_DELETE_NETWORK}"
  classify_ai_mutation "neutron network delete" "${RUN_OUTPUT}" "${RUN_STATUS}"
fi

echo
echo "== Cinder create denial =="
run_ai openstack volume create --size "${VOLUME_SIZE}" "${CINDER_CREATE_VOLUME}"
classify_ai_create "cinder volume create" "${CINDER_CREATE_VOLUME}" "${RUN_OUTPUT}" "${RUN_STATUS}" volume show

echo
echo "== Cinder update denial =="
if create_fixture "cinder volume update fixture" "Cinder update fixture volume" "${CINDER_UPDATE_VOLUME}" openstack volume create --size "${VOLUME_SIZE}" -f value -c id "${CINDER_UPDATE_VOLUME}"; then
  run_ai openstack volume set --name "${CINDER_UPDATE_VOLUME}-renamed" "${CINDER_UPDATE_VOLUME}"
  classify_ai_mutation "cinder volume set" "${RUN_OUTPUT}" "${RUN_STATUS}"
fi

echo
echo "== Cinder delete denial =="
if create_fixture "cinder volume delete fixture" "Cinder delete fixture volume" "${CINDER_DELETE_VOLUME}" openstack volume create --size "${VOLUME_SIZE}" -f value -c id "${CINDER_DELETE_VOLUME}"; then
  run_ai openstack volume delete "${CINDER_DELETE_VOLUME}"
  classify_ai_mutation "cinder volume delete" "${RUN_OUTPUT}" "${RUN_STATUS}"
fi

echo
echo "== Glance create denial =="
run_ai openstack image create --disk-format raw --container-format bare --file "${IMAGE_FILE}" "${GLANCE_CREATE_IMAGE}"
classify_ai_create "glance image create" "${GLANCE_CREATE_IMAGE}" "${RUN_OUTPUT}" "${RUN_STATUS}" image show

echo
echo "== Glance update denial =="
if create_fixture "glance image update fixture" "Glance update fixture image" "${GLANCE_UPDATE_IMAGE}" openstack image create --disk-format raw --container-format bare --file "${IMAGE_FILE}" -f value -c id "${GLANCE_UPDATE_IMAGE}"; then
  run_ai openstack image set --name "${GLANCE_UPDATE_IMAGE}-renamed" "${GLANCE_UPDATE_IMAGE}"
  classify_ai_mutation "glance image set" "${RUN_OUTPUT}" "${RUN_STATUS}"
fi

echo
echo "== Glance delete denial =="
if create_fixture "glance image delete fixture" "Glance delete fixture image" "${GLANCE_DELETE_IMAGE}" openstack image create --disk-format raw --container-format bare --file "${IMAGE_FILE}" -f value -c id "${GLANCE_DELETE_IMAGE}"; then
  run_ai openstack image delete "${GLANCE_DELETE_IMAGE}"
  classify_ai_mutation "glance image delete" "${RUN_OUTPUT}" "${RUN_STATUS}"
fi

if [[ "${SKIP_OCTAVIA}" != "yes" ]]; then
  echo
  echo "== Octavia create denial =="
  run_ai openstack loadbalancer create --name "${OCTAVIA_CREATE_LB}" --vip-subnet-id "${SUBNET_ID}" --wait
  classify_ai_create "octavia loadbalancer create" "${OCTAVIA_CREATE_LB}" "${RUN_OUTPUT}" "${RUN_STATUS}" loadbalancer show

  echo
  echo "== Octavia update denial =="
  if create_fixture "octavia loadbalancer update fixture" "Octavia update fixture load balancer" "${OCTAVIA_UPDATE_LB}" openstack loadbalancer create --name "${OCTAVIA_UPDATE_LB}" --vip-subnet-id "${SUBNET_ID}" --wait -f value -c id; then
    run_ai openstack loadbalancer set --name "${OCTAVIA_UPDATE_LB}-renamed" "${OCTAVIA_UPDATE_LB}"
    classify_ai_mutation "octavia loadbalancer set" "${RUN_OUTPUT}" "${RUN_STATUS}"
  fi

  echo
  echo "== Octavia delete denial =="
  if create_fixture "octavia loadbalancer delete fixture" "Octavia delete fixture load balancer" "${OCTAVIA_DELETE_LB}" openstack loadbalancer create --name "${OCTAVIA_DELETE_LB}" --vip-subnet-id "${SUBNET_ID}" --wait -f value -c id; then
    run_ai openstack loadbalancer delete --cascade --wait "${OCTAVIA_DELETE_LB}"
    classify_ai_mutation "octavia loadbalancer delete" "${RUN_OUTPUT}" "${RUN_STATUS}"
  fi
else
  echo
  record_skip "Octavia deep probes disabled by --skip-octavia" ""
fi

echo
echo "== System-scope Keystone mutation denial =="
run_ai_system openstack project set --description "${BASE} system-scope mutation probe" "${PROJECT_ID}"
classify_ai_mutation "system keystone project set" "${RUN_OUTPUT}" "${RUN_STATUS}"

run_ai_system openstack role create "${SYSTEM_CREATE_ROLE}"
classify_ai_mutation "system keystone role create" "${RUN_OUTPUT}" "${RUN_STATUS}"

echo
echo "== System-scope Nova mutation denial =="
run_ai_system openstack flavor create --ram 64 --disk 1 --vcpus 1 "${SYSTEM_CREATE_FLAVOR}"
classify_ai_mutation "system nova flavor create" "${RUN_OUTPUT}" "${RUN_STATUS}"

echo
echo "== System-scope Cinder mutation denial =="
run_ai_system openstack volume type create "${SYSTEM_CREATE_VOLUME_TYPE}"
classify_ai_mutation "system cinder volume type create" "${RUN_OUTPUT}" "${RUN_STATUS}"

echo
echo "== System-scope Keystone delete denial =="
run_ai_system openstack user delete "${KEYSTONE_DELETE_USER_ID}"
classify_ai_mutation "system keystone user delete" "${RUN_OUTPUT}" "${RUN_STATUS}"

run_ai_system openstack project delete "${KEYSTONE_DELETE_PROJECT_ID}"
classify_ai_mutation "system keystone project delete" "${RUN_OUTPUT}" "${RUN_STATUS}"

echo
echo "== System-scope Keystone user mutation denial =="
run_ai_system openstack user set --disable "${USER_ID}"
classify_ai_mutation "system keystone user disable" "${RUN_OUTPUT}" "${RUN_STATUS}"

echo
echo "Deep mutation summary: ${passed} passed, ${skipped} skipped, ${inconclusive} inconclusive, ${failed} failed."

if (( failed > 0 )); then
  exit 1
fi

if (( inconclusive > 0 )); then
  exit 2
fi

exit 0
