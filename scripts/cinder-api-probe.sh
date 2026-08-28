#!/usr/bin/env bash
set -u

usage() {
  echo "Usage: cinder-api-probe.sh <attach|detach|group-spec-list|group-spec-show|host-list|reserve|unreserve> [resource-id] [instance-id-or-spec-key]" >&2
  exit 2
}

if (( $# < 1 )); then
  usage
fi

ACTION="$1"
RESOURCE_ID="${2:-}"
ACTION_VALUE="${3:-}"

case "${ACTION}" in
  attach)
    [[ -n "${RESOURCE_ID}" && -n "${ACTION_VALUE}" ]] || usage
    METHOD="POST"
    PATH_SUFFIX="/volumes/${RESOURCE_ID}/action"
    BODY="{\"os-attach\":{\"instance_uuid\":\"${ACTION_VALUE}\",\"mountpoint\":\"/dev/vdb\",\"mode\":\"rw\"}}"
    ;;
  detach)
    [[ -n "${RESOURCE_ID}" ]] || usage
    METHOD="POST"
    PATH_SUFFIX="/volumes/${RESOURCE_ID}/action"
    BODY='{"os-detach":{}}'
    ;;
  group-spec-show)
    [[ -n "${RESOURCE_ID}" && -n "${ACTION_VALUE}" ]] || usage
    METHOD="GET"
    PATH_SUFFIX="/group_types/${RESOURCE_ID}/group_specs/${ACTION_VALUE}"
    BODY=""
    ;;
  group-spec-list)
    [[ -n "${RESOURCE_ID}" ]] || usage
    METHOD="GET"
    PATH_SUFFIX="/group_types/${RESOURCE_ID}/group_specs"
    BODY=""
    ;;
  host-list)
    METHOD="GET"
    PATH_SUFFIX="/os-hosts"
    BODY=""
    ;;
  reserve)
    [[ -n "${RESOURCE_ID}" ]] || usage
    METHOD="POST"
    PATH_SUFFIX="/volumes/${RESOURCE_ID}/action"
    BODY='{"os-reserve":null}'
    ;;
  unreserve)
    [[ -n "${RESOURCE_ID}" ]] || usage
    METHOD="POST"
    PATH_SUFFIX="/volumes/${RESOURCE_ID}/action"
    BODY='{"os-unreserve":null}'
    ;;
  *)
    usage
    ;;
esac

TOKEN="$(openstack token issue -f value -c id 2>/dev/null)" || {
  echo "Unable to issue token for Cinder API probe" >&2
  exit 1
}

INTERFACE="${OS_INTERFACE:-public}"
INTERFACE="${INTERFACE%URL}"
INTERFACE="${INTERFACE,,}"
ENDPOINT="${OS_VOLUME_ENDPOINT_OVERRIDE:-${CINDER_ENDPOINT:-}}"

if [[ -z "${ENDPOINT}" ]]; then
  for service in volumev3 cinderv3 block-storage volume; do
    CATALOG_OUTPUT="$(openstack catalog show "${service}" -f json 2>/dev/null)" || continue
    ENDPOINT="$(python3 -c '
import json
import re
import sys

interface = sys.argv[1]
endpoints = json.load(sys.stdin).get("endpoints", [])
if isinstance(endpoints, list):
    for endpoint in endpoints:
        if isinstance(endpoint, dict) and endpoint.get("interface") == interface:
            print(endpoint.get("url", ""))
            break
elif isinstance(endpoints, str):
    match = re.search(r"(?:^|\s)" + re.escape(interface) + r":\s*(\S+)", endpoints)
    if match:
        print(match.group(1))
' "${INTERFACE}" <<<"${CATALOG_OUTPUT}")"
    [[ -n "${ENDPOINT}" ]] && break
  done
fi

if [[ -z "${ENDPOINT}" ]]; then
  echo "Unable to discover a Cinder endpoint from the token catalog" >&2
  exit 1
fi

RESPONSE_FILE="$(mktemp /tmp/cinder-api-probe.XXXXXX)"
trap 'rm -f "${RESPONSE_FILE}"' EXIT
CURL_ARGS=(
  --silent
  --show-error
  --output "${RESPONSE_FILE}"
  --write-out '%{http_code}'
  --request "${METHOD}"
  --header "X-Auth-Token: ${TOKEN}"
  --header 'OpenStack-API-Version: volume 3.27'
  --header 'Content-Type: application/json'
)

if [[ "${OS_INSECURE:-false}" =~ ^([Tt][Rr][Uu][Ee]|1|yes)$ ]]; then
  CURL_ARGS+=(--insecure)
elif [[ -n "${OS_CACERT:-}" ]]; then
  CURL_ARGS+=(--cacert "${OS_CACERT}")
fi
if [[ -n "${BODY}" ]]; then
  CURL_ARGS+=(--data "${BODY}")
fi

HTTP_STATUS="$(curl "${CURL_ARGS[@]}" "${ENDPOINT%/}${PATH_SUFFIX}")"
CURL_STATUS=$?
cat "${RESPONSE_FILE}"
echo

if (( CURL_STATUS != 0 )); then
  exit "${CURL_STATUS}"
fi
if [[ "${HTTP_STATUS}" =~ ^2[0-9][0-9]$ ]]; then
  exit 0
fi

echo "HTTP ${HTTP_STATUS}" >&2
exit 1
