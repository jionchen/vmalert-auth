# vmalert-auth

Custom VictoriaMetrics `vmalert` image with authenticated HTTP rule-source support using VictoriaMetrics `lib/promauth`.

Current build metadata is centralized in:

```text
versions.env
```

Current production image pattern:

```text
ghcr.io/jionchen/vmalert-auth:<VM_VERSION>-custom-nocgo
```

For the current repository state this resolves to:

```text
ghcr.io/jionchen/vmalert-auth:v1.150.0-custom-nocgo
```

## Why `nocgo`

The target Docker environment previously rejected CGO thread creation with:

```text
runtime/cgo: pthread_create failed: Operation not permitted
```

The project therefore intentionally builds Linux amd64 with:

```text
CGO_ENABLED=0
-tags 'netgo osusergo'
```

Do not switch production builds back to CGO just to match upstream's default amd64 build.

## Authenticated HTTP rule source

Create a password file:

```bash
mkdir -p /data/victoriametrics/victoria-metrics-secrets
printf '%s' 'your-password' > /data/victoriametrics/victoria-metrics-secrets/rule_password
chmod 600 /data/victoriametrics/victoria-metrics-secrets/rule_password
```

Create `rule-source.yml`:

```yaml
rule:
  url: http://xx.xx.xx.xx:8091/runtime/v1/vmalert/groups/vmalert-datasource-2/rules
  basic_auth:
    username: your-username
    password_file: /etc/victoriametrics/secrets/rule_password
```

Run vmalert with:

```text
-rule.auth.config=/victoria-metrics-config/rule/rule-source.yml
```

Do **not** pass `rule-source.yml` to normal `-rule=`. A normal rule file must contain top-level `groups:`.

Example Compose fragment:

```yaml
vmalert:
  image: ghcr.io/jionchen/vmalert-auth:v1.150.0-custom-nocgo
  volumes:
    - /data/victoriametrics/victoria-metrics-config/rule:/victoria-metrics-config/rule:ro
    - /data/victoriametrics/victoria-metrics-secrets:/etc/victoriametrics/secrets:ro
  command:
    - "-rule.auth.config=/victoria-metrics-config/rule/rule-source.yml"
    - "-configCheckInterval=1m"
    - "-datasource.url=http://victoriametrics:8428"
```

Existing local/public rule sources remain supported with normal `-rule=` flags.

## Repository layout

```text
versions.env                              centralized upstream/build versions
Dockerfile                                no-cgo production build
UPGRADE.md                                human upgrade SOP

overlay/app/vmalert/rule_auth.go         -rule.auth.config implementation
overlay/app/vmalert/config/fsurl/url.go    authenticated HTTP fetch

scripts/apply-overlay.sh                  applies customization to upstream source
scripts/upgrade-check.sh                  checks target upstream compatibility
scripts/set-version.sh                    updates versions.env from target upstream
scripts/build-local.sh                    builds, tests and exports docker-load package
scripts/smoke-basic-auth.py               Basic Auth integration test server

skills/vmalert-auth-upgrade/SKILL.md      reusable coding-agent upgrade skill
.github/workflows/build-image.yml          validate first, then publish image/artifact
```

## Upgrade upstream VictoriaMetrics

Read:

```text
UPGRADE.md
```

Typical flow:

```bash
git checkout -b upgrade-v1.151.0

bash scripts/upgrade-check.sh v1.151.0
bash scripts/set-version.sh v1.151.0

git diff

bash scripts/build-local.sh
```

Only after all local gates pass should the change be merged to `main`.

GitHub Actions then performs:

```text
build image
  -> verify version
  -> verify -rule.auth.config
  -> verify no CGO/dynamic dependency
  -> Basic Auth + password_file -dryRun
  -> push immutable image tag
  -> update latest
  -> export docker-load artifact + SHA256
```

## Agent Skill

The repository contains a reusable skill at:

```text
skills/vmalert-auth-upgrade/SKILL.md
```

Give that skill to a coding agent when upgrading the upstream VictoriaMetrics version. It defines the required source inspection, overlay rebase rules, build gates, image packaging and rollback information.

## Offline image

GitHub Actions produces:

```text
vmalert-auth-<VM_VERSION>-custom-nocgo-linux-amd64.tar.gz
vmalert-auth-<VM_VERSION>-custom-nocgo-linux-amd64.tar.gz.sha256
```

Load with:

```bash
gunzip vmalert-auth-<version>-linux-amd64.tar.gz
docker load -i vmalert-auth-<version>-linux-amd64.tar
```

## Long-term maintenance goal

On every upstream upgrade, first check whether VictoriaMetrics has added native authenticated HTTP `-rule` source support with `password_file`. If upstream provides equivalent behavior, prefer the official implementation and retire this overlay.
