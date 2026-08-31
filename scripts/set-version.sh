#!/usr/bin/env bash
set -euo pipefail

TARGET_VERSION="${1:-}"
if [[ -z "${TARGET_VERSION}" ]]; then
  echo "usage: $0 <target-victoriametrics-tag>" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
# shellcheck disable=SC1091
source ./versions.env

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/VictoriaMetrics/VictoriaMetrics.git}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "==> reading build metadata from upstream ${TARGET_VERSION}"
git clone --quiet --depth 1 --branch "${TARGET_VERSION}" "${UPSTREAM_REPO}" "${TMP_DIR}/upstream"

GO_VERSION_NEW="$(awk '$1 == "go" { print $2; exit }' "${TMP_DIR}/upstream/go.mod")"
ROOT_IMAGE_NEW="$(awk '/^ROOT_IMAGE \?=/{print $3; exit}' "${TMP_DIR}/upstream/deployment/docker/Makefile")"

if [[ -z "${GO_VERSION_NEW}" || -z "${ROOT_IMAGE_NEW}" ]]; then
  echo "ERROR: failed to determine GO_VERSION or ROOT_IMAGE from upstream" >&2
  exit 1
fi

cat > versions.env <<EOF
# Single source of truth for the custom vmalert build.
# Update this file through scripts/set-version.sh when upgrading upstream.
VM_VERSION=${TARGET_VERSION}
GO_VERSION=${GO_VERSION_NEW}
ROOT_IMAGE=${ROOT_IMAGE_NEW}
IMAGE_SUFFIX=${IMAGE_SUFFIX}
EOF

cat versions.env

echo
echo "Updated versions.env. Review git diff before building."
