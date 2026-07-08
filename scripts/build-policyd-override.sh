#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"

mkdir -p "${DIST_DIR}"

build_zip() {
  local service="$1"
  local src_dir="${ROOT_DIR}/overrides/${service}"
  local zip_file="${DIST_DIR}/${service}-policyd-override.zip"

  if [[ ! -d "${src_dir}" ]]; then
    echo "Missing source dir: ${src_dir}" >&2
    return 1
  fi

  rm -f "${zip_file}"
  (
    cd "${src_dir}"
    zip -q -r "${zip_file}" ./*.yaml
  )

  echo "Built ${zip_file}"
}

for svc in keystone nova neutron cinder glance octavia; do
  build_zip "${svc}"
done

echo "All policy override archives created under ${DIST_DIR}"
