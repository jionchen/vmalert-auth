---
name: vmalert-auth-upgrade
description: Upgrade, rebase, validate, build, package, and prepare deployment artifacts for the custom jionchen/vmalert-auth image based on upstream VictoriaMetrics vmalert. Use this skill when the upstream VictoriaMetrics/vmalert version changes, when the custom Basic Auth/password_file rule-source overlay must be rebased, or when a new docker image/offline docker-load package must be produced.
---

# vmalert-auth Upgrade Skill

Use this skill only for the `jionchen/vmalert-auth` customization that adds authenticated HTTP rule-source loading to VictoriaMetrics `vmalert`.

The customization provides:

```text
-rule.auth.config=/path/to/rule-source.yml
```

with:

```yaml
rule:
  url: http://example:8091/runtime/v1/vmalert/groups/example/rules
  basic_auth:
    username: vmalert
    password_file: /etc/victoriametrics/secrets/rule_password
```

The expected production image suffix is:

```text
custom-nocgo
```

## Goal

Given a requested target upstream VictoriaMetrics tag, complete the workflow from source inspection through a validated Docker image and offline `docker load` package.

Do not consider the task complete merely because the code compiles. The required completion gates are listed below.

## Repository model

This repository is **not** a full VictoriaMetrics fork.

It uses:

```text
upstream VictoriaMetrics tag
        +
custom overlay
        +
main.go injection
        +
no-cgo Docker build
```

Key files:

```text
versions.env
Dockerfile
UPGRADE.md

overlay/app/vmalert/rule_auth.go
overlay/app/vmalert/config/fsurl/url.go

scripts/apply-overlay.sh
scripts/upgrade-check.sh
scripts/set-version.sh
scripts/build-local.sh
scripts/smoke-basic-auth.py

.github/workflows/build-image.yml
```

## Non-negotiable invariants

Preserve all of these unless the user explicitly asks for a redesign:

1. Build Linux amd64 with `CGO_ENABLED=0`.
2. Do not use URL credentials such as `http://user:password@host/...` for the custom rule source.
3. Do not add plaintext `password:` support to the custom rule-source YAML.
4. Use `password_file` through VictoriaMetrics `lib/promauth`.
5. Do not manually Base64-encode Basic Auth credentials in the implementation.
6. Apply auth only to the exact configured rule URL.
7. Preserve normal upstream `-rule` behavior.
8. Keep `-rule.auth.config` separate from normal rule files.
9. Register authenticated rule-source configuration before the first config/rule read.
10. Production and release tags must be immutable, e.g. `v1.151.0-custom-nocgo`; never recommend `latest` for production.
11. A build that has a dynamic libc/cgo dependency is invalid for this deployment environment.

The no-cgo requirement exists because a CGO-enabled build previously failed on the target Docker host with:

```text
runtime/cgo: pthread_create failed: Operation not permitted
```

Do not “fix” that by recommending `seccomp=unconfined` for production.

## Phase 1 — Read current project state

Before editing anything:

```bash
pwd
git status --short
git branch --show-current
cat versions.env
```

Read at minimum:

```text
Dockerfile
versions.env
overlay/app/vmalert/rule_auth.go
overlay/app/vmalert/config/fsurl/url.go
scripts/apply-overlay.sh
.github/workflows/build-image.yml
UPGRADE.md
```

Determine:

```text
current VM_VERSION
current GO_VERSION
current ROOT_IMAGE
current IMAGE_SUFFIX
requested target VictoriaMetrics tag
```

If the user did not specify a target tag, do not silently upgrade to an arbitrary version. Ask for or resolve the intended stable tag when appropriate.

## Phase 2 — Inspect upstream before changing local code

Run:

```bash
./scripts/upgrade-check.sh <target-tag>
```

Also inspect the target upstream source directly.

Clone a temporary upstream tree if needed:

```bash
tmp=$(mktemp -d)
git clone --depth 1 --branch <target-tag> \
  https://github.com/VictoriaMetrics/VictoriaMetrics.git \
  "$tmp/VictoriaMetrics"
```

Inspect these target files:

```text
app/vmalert/main.go
app/vmalert/config/fsurl/url.go
lib/promauth/config.go
app/vmalert/Makefile
deployment/docker/Makefile
go.mod
```

Compare the current upstream tag to the target upstream tag for the same files.

## Phase 3 — Check whether the customization is still necessary

Before rebasing custom code, search the target upstream for native support:

```bash
git grep -n "rule.auth" -- app/vmalert
git grep -n "password_file" -- app/vmalert
git grep -n "BasicAuth" -- app/vmalert
```

If upstream now supports authenticated HTTP `-rule` sources with equivalent `basic_auth.username + password_file` behavior:

1. Stop carrying the overlay automatically.
2. Explain that upstream functionality may replace the custom implementation.
3. Compare semantics, especially password-file reload behavior and per-source auth.
4. Prefer migration to official functionality when equivalent.

Do not maintain a redundant fork without a reason.

## Phase 4 — Validate integration APIs

The current implementation relies on:

```go
promauth.BasicAuthConfig
(*promauth.BasicAuthConfig).NewConfig(baseDir)
(*promauth.Config).SetHeaders(req, true)
```

Verify all still exist in target `lib/promauth/config.go`.

Also verify target `app/vmalert/config/fsurl/url.go` still has a compatible HTTP loading path.

If any required API changed, do not duplicate secret-reading or auth logic locally. Rebase onto the new `promauth` API.

## Phase 5 — Review the main.go injection point

Current `scripts/apply-overlay.sh` expects this anchor in upstream `app/vmalert/main.go`:

```go
logger.Init()

var err error
```

It injects authenticated rule registration before normal rule parsing.

If this anchor no longer exists:

1. Read the new startup flow.
2. Locate the point after flag parsing/logger initialization but before the first `config.Parse`, `ReadFromFS`, or equivalent rule load.
3. Update `scripts/apply-overlay.sh` to inject there.
4. Do not weaken the script into an unverified broad text replacement.

The script should fail loudly if the expected upstream structure is no longer present.

## Phase 6 — Rebase fsurl correctly

The current overlay replaces:

```text
overlay/app/vmalert/config/fsurl/url.go
```

This is the highest-risk file during an upstream upgrade.

If target upstream `url.go` changed:

1. Start from the **target upstream `url.go`**.
2. Re-add only the minimal custom pieces:
   - `promauth` import;
   - exact-URL auth registry;
   - `RegisterAuth`;
   - `getAuth`;
   - request creation if needed;
   - `authCfg.SetHeaders(req, true)` before sending the request.
3. Preserve all new upstream behavior around status handling, redirects, bodies, timeouts, transports, URL parsing, observability, or errors.
4. Never discard upstream improvements just to retain the old overlay file.

Credential isolation rule:

```text
auth for URL A must never be sent to URL B
```

This is why the registry key is the exact rule URL.

## Phase 7 — Preserve rule_auth.go semantics

The custom `rule_auth.go` should continue to enforce:

```text
rule.url is required
scheme must be http or https
host is required
URL userinfo is rejected
rule.basic_auth is required
username is required
password_file is required
unknown YAML fields are rejected
```

Then create:

```go
&promauth.BasicAuthConfig{
    Username: username,
    PasswordFile: passwordFile,
}
```

and call:

```go
NewConfig(baseDir)
```

so relative password paths resolve relative to the auth-config file.

Do not read the password once at startup and store a fixed header. `promauth` must remain responsible for password-file loading/caching/rotation behavior.

## Phase 8 — Update project version metadata

After source compatibility review passes:

```bash
./scripts/set-version.sh <target-tag>
```

This must update `versions.env` from the target upstream source.

Review:

```bash
cat versions.env
git diff -- versions.env
```

Expected keys:

```text
VM_VERSION
GO_VERSION
ROOT_IMAGE
IMAGE_SUFFIX
```

Normally keep:

```text
IMAGE_SUFFIX=custom-nocgo
```

Do not hard-code version changes independently across multiple files if `versions.env` can provide them.

## Phase 9 — Build configuration requirements

The Docker build must receive values from `versions.env` and must build with:

```text
CGO_ENABLED=0
GOOS=linux
GOARCH=amd64
-tags 'netgo osusergo'
```

The custom buildinfo must identify the image, for example:

```text
vmalert-v1.151.0-custom-nocgo
```

Keep an Alpine-compatible runtime image unless target upstream changes its standard root image and there is a reason to follow it.

## Phase 10 — Run local build gates

Run:

```bash
./scripts/build-local.sh
```

Do not skip failures.

The script must validate:

### Gate A — Build

The target upstream source clones and the overlay applies successfully.

### Gate B — Go tests

At minimum the packages touched by the customization compile/test successfully.

### Gate C — Version

```bash
vmalert -version
```

contains the expected custom version.

### Gate D — Flag

```text
-rule.auth.config
```

appears in help.

### Gate E — no-cgo

Extract `/vmalert-prod` from the image and verify it is static / has no dynamic dependency.

Any dynamic dependency is a release blocker.

### Gate F — Real Basic Auth request

Start the repository's test server and verify that:

```text
username comes from rule-source.yml
password comes from password_file
Authorization is accepted by the server
```

### Gate G — Rule parsing

Run:

```text
-dryRun
```

and successfully parse the returned `groups:` rule YAML.

### Gate H — Offline package

Produce:

```text
vmalert-auth-<version>-linux-amd64.tar.gz
vmalert-auth-<version>-linux-amd64.tar.gz.sha256
```

## Phase 11 — Test the real endpoint before release

When the production rule config is available, run a dry-run using the production mount layout.

Example:

```bash
docker run --rm \
  --network vmnet \
  -v /data/victoriametrics/victoria-metrics-config/rule:/victoria-metrics-config/rule:ro \
  -v /data/victoriametrics/victoria-metrics-secrets:/etc/victoriametrics/secrets:ro \
  vmalert-auth:<target-tag>-custom-nocgo \
  -rule.auth.config=/victoria-metrics-config/rule/rule-source.yml \
  -dryRun
```

Interpret common failures:

```text
401
  => username or password file content is wrong

connection refused / timeout
  => endpoint/network problem

failed to parse
  => remote rule endpoint returned invalid vmalert YAML

unknown fields in config: rule
  => rule-source.yml was incorrectly passed to -rule= instead of -rule.auth.config=

runtime/cgo: pthread_create failed
  => wrong CGO-enabled image was built or deployed
```

## Phase 12 — CI release behavior

The preferred CI order is:

```text
build image locally
    ↓
version test
    ↓
no-cgo test
    ↓
Basic Auth/password_file dryRun
    ↓
only then push version tag
    ↓
push latest only after all gates pass
    ↓
export docker-load artifact
```

Do not push a release/version tag before validation succeeds.

## Phase 13 — Release naming

For target upstream `v1.151.0`, use:

```text
ghcr.io/jionchen/vmalert-auth:v1.151.0-custom-nocgo
```

The offline package should be named consistently:

```text
vmalert-auth-v1.151.0-custom-nocgo-linux-amd64.tar.gz
```

## Phase 14 — Deployment guidance

Production Compose should use the versioned tag, not `latest`:

```yaml
image: ghcr.io/jionchen/vmalert-auth:v1.151.0-custom-nocgo
```

Authenticated rule configuration is passed with:

```yaml
command:
  - "-rule.auth.config=/victoria-metrics-config/rule/rule-source.yml"
```

Never pass `rule-source.yml` to normal `-rule=`. Normal `-rule=` is only for real vmalert rule YAML whose top-level field is `groups:`.

## Phase 15 — Rollback

Always retain the previous immutable image tag.

Rollback means restoring the previous Compose image value and recreating only vmalert:

```bash
docker compose up -d --no-deps --force-recreate vmalert
```

Do not delete the previous image/package until the new version has been proven stable.

## Required final report

When this skill is used for an upgrade, report all of the following:

```text
old upstream version
target upstream version
upstream Go version
upstream root image
whether upstream native auth support was found
critical upstream files changed
whether overlay code needed modification
main.go injection compatibility
promauth API compatibility
CGO status
Go test result
version test result
rule.auth.config flag test result
Basic Auth/password_file dryRun result
real endpoint dryRun result, if available
final image tag
offline archive name
SHA256
rollback image tag
```

If a gate was not actually executed, explicitly say so. Never claim a build or test passed based only on code inspection.
