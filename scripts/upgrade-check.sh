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

CURRENT_DIR="${TMP_DIR}/current"
TARGET_DIR="${TMP_DIR}/target"

echo "==> cloning upstream ${VM_VERSION}"
git clone --quiet --depth 1 --branch "${VM_VERSION}" "${UPSTREAM_REPO}" "${CURRENT_DIR}"

echo "==> cloning upstream ${TARGET_VERSION}"
git clone --quiet --depth 1 --branch "${TARGET_VERSION}" "${UPSTREAM_REPO}" "${TARGET_DIR}"

critical_files=(
  app/vmalert/main.go
  app/vmalert/config/fsurl/url.go
  lib/promauth/config.go
  app/vmalert/Makefile
  deployment/docker/Makefile
  go.mod
)

echo
echo "==> critical upstream changes ${VM_VERSION} -> ${TARGET_VERSION}"
for f in "${critical_files[@]}"; do
  echo "---- ${f} ----"
  if cmp -s "${CURRENT_DIR}/${f}" "${TARGET_DIR}/${f}"; then
    echo "unchanged"
  else
    git --no-pager diff --no-index --stat "${CURRENT_DIR}/${f}" "${TARGET_DIR}/${f}" || true
  fi
done

echo
echo "==> checking whether upstream now has native authenticated rule-source support"
if git -C "${TARGET_DIR}" grep -n -E 'rule\.auth|password_file|BasicAuth' -- app/vmalert 2>/dev/null | head -n 40; then
  echo "NOTE: matches were found. Review them before carrying the custom overlay forward."
else
  echo "no obvious native implementation found under app/vmalert"
fi

echo
echo "==> validating required promauth APIs"
grep -q 'type BasicAuthConfig struct' "${TARGET_DIR}/lib/promauth/config.go" || {
  echo "ERROR: promauth.BasicAuthConfig no longer has the expected declaration" >&2
  exit 1
}
grep -q 'func (ba \*BasicAuthConfig) NewConfig' "${TARGET_DIR}/lib/promauth/config.go" || {
  echo "ERROR: promauth.BasicAuthConfig.NewConfig changed or disappeared" >&2
  exit 1
}
grep -q 'func (ac \*Config) SetHeaders' "${TARGET_DIR}/lib/promauth/config.go" || {
  echo "ERROR: promauth.Config.SetHeaders changed or disappeared" >&2
  exit 1
}

echo "promauth APIs: OK"

echo
echo "==> validating fsurl integration surface"
grep -q 'type FS struct' "${TARGET_DIR}/app/vmalert/config/fsurl/url.go" || {
  echo "ERROR: fsurl.FS structure changed materially" >&2
  exit 1
}
grep -q 'func (fs \*FS) Read' "${TARGET_DIR}/app/vmalert/config/fsurl/url.go" || {
  echo "ERROR: fsurl.FS.Read changed materially" >&2
  exit 1
}
echo "fsurl integration surface: OK"

echo
echo "==> validating main.go patch anchor"
python3 - "${TARGET_DIR}/app/vmalert/main.go" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
needle = "\tlogger.Init()\n\n\tvar err error\n"
if needle not in s:
    raise SystemExit("ERROR: apply-overlay.sh main.go anchor no longer matches upstream")
print("main.go patch anchor: OK")
PY

TARGET_GO_VERSION="$(awk '$1 == "go" { print $2; exit }' "${TARGET_DIR}/go.mod")"
TARGET_ROOT_IMAGE="$(awk '/^ROOT_IMAGE \?=/{print $3; exit}' "${TARGET_DIR}/deployment/docker/Makefile")"

echo
echo "==> target build metadata"
echo "VM_VERSION=${TARGET_VERSION}"
echo "GO_VERSION=${TARGET_GO_VERSION}"
echo "ROOT_IMAGE=${TARGET_ROOT_IMAGE}"

echo
echo "Compatibility gates passed."
echo "Next: review the changed critical files, then run: scripts/set-version.sh ${TARGET_VERSION}"
