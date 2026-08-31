#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-/src}"
OVERLAY="${2:-/overlay}"

cp "${OVERLAY}/app/vmalert/config/fsurl/url.go" "${ROOT}/app/vmalert/config/fsurl/url.go"
cp "${OVERLAY}/app/vmalert/rule_auth.go" "${ROOT}/app/vmalert/rule_auth.go"

python3 - "${ROOT}/app/vmalert/main.go" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
needle = '''\tlogger.Init()\n\n\tvar err error\n'''
replacement = '''\tlogger.Init()\n\n\tvar err error\n\truleAuthURL, err := initRuleAuth()\n\tif err != nil {\n\t\tlogger.Fatalf("failed to initialize HTTP rule authentication: %s", err)\n\t}\n\tif ruleAuthURL != "" {\n\t\t*rulePath = append(*rulePath, ruleAuthURL)\n\t}\n'''
if needle not in s:
    raise SystemExit("cannot find expected logger.Init()/var err block in upstream app/vmalert/main.go")
if 'ruleAuthURL, err := initRuleAuth()' in s:
    raise SystemExit("rule auth initialization is already present in app/vmalert/main.go")
p.write_text(s.replace(needle, replacement, 1))
PY

gofmt -w \
  "${ROOT}/app/vmalert/main.go" \
  "${ROOT}/app/vmalert/rule_auth.go" \
  "${ROOT}/app/vmalert/config/fsurl/url.go"
