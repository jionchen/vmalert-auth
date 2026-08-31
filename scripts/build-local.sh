#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
# shellcheck disable=SC1091
source ./versions.env

IMAGE_NAME="${IMAGE_NAME:-vmalert-auth}"
IMAGE_TAG="${VM_VERSION}-${IMAGE_SUFFIX}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
ARCHIVE_NAME="vmalert-auth-${IMAGE_TAG}-linux-amd64.tar.gz"

echo "==> building ${FULL_IMAGE}"
docker build --pull \
  --build-arg "VM_VERSION=${VM_VERSION}" \
  --build-arg "GO_VERSION=${GO_VERSION}" \
  --build-arg "ROOT_IMAGE=${ROOT_IMAGE}" \
  --build-arg "IMAGE_SUFFIX=${IMAGE_SUFFIX}" \
  -t "${FULL_IMAGE}" .

echo
echo "==> verifying version metadata"
docker run --rm "${FULL_IMAGE}" -version 2>&1 | tee /tmp/vmalert-auth-version.txt
grep -F "vmalert-${IMAGE_TAG}" /tmp/vmalert-auth-version.txt

echo
echo "==> verifying custom flag"
docker run --rm "${FULL_IMAGE}" -help 2>&1 | grep -F -- '-rule.auth.config'

echo
echo "==> verifying no cgo / dynamic dependency"
container_id="$(docker create "${FULL_IMAGE}")"
trap 'docker rm -f "${container_id}" >/dev/null 2>&1 || true' EXIT
docker cp "${container_id}:/vmalert-prod" /tmp/vmalert-prod
file /tmp/vmalert-prod
if ldd /tmp/vmalert-prod 2>&1 | grep -v 'not a dynamic executable' | grep -q .; then
  echo "ERROR: unexpected dynamic dependency detected" >&2
  ldd /tmp/vmalert-prod || true
  exit 1
fi
docker rm -f "${container_id}" >/dev/null
trap - EXIT

echo
echo "==> verifying Basic Auth password_file with -dryRun"
rm -rf smoke
mkdir -p smoke
python3 scripts/smoke-basic-auth.py &
server_pid=$!
trap 'kill "${server_pid}" >/dev/null 2>&1 || true; rm -rf smoke' EXIT
sleep 1
printf '%s' 'secret-v1' > smoke/password
cat > smoke/rule-source.yml <<'YAML'
rule:
  url: http://host.docker.internal:18080/rules
  basic_auth:
    username: vmalert
    password_file: /etc/vmalert/password
YAML

docker run --rm \
  --add-host host.docker.internal:host-gateway \
  -v "$PWD/smoke/rule-source.yml:/etc/vmalert/rule-source.yml:ro" \
  -v "$PWD/smoke/password:/etc/vmalert/password:ro" \
  "${FULL_IMAGE}" \
  -rule.auth.config=/etc/vmalert/rule-source.yml \
  -dryRun

kill "${server_pid}" >/dev/null 2>&1 || true
rm -rf smoke
trap - EXIT

echo
echo "==> exporting docker load archive"
docker save "${FULL_IMAGE}" | gzip -1 > "${ARCHIVE_NAME}"
sha256sum "${ARCHIVE_NAME}" > "${ARCHIVE_NAME}.sha256"
ls -lh "${ARCHIVE_NAME}" "${ARCHIVE_NAME}.sha256"

echo
echo "All checks passed."
echo "Image: ${FULL_IMAGE}"
echo "Archive: ${ARCHIVE_NAME}"
