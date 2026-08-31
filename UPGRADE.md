# vmalert-auth Upgrade SOP

This repository builds a custom VictoriaMetrics `vmalert` with authenticated HTTP rule-source support:

```yaml
rule:
  url: http://example:8091/runtime/v1/vmalert/groups/example/rules
  basic_auth:
    username: vmalert
    password_file: /etc/victoriametrics/secrets/rule_password
```

The runtime flag is:

```text
-rule.auth.config=/path/to/rule-source.yml
```

The project intentionally uses an **upstream source + overlay** model instead of keeping a full VictoriaMetrics fork.

## 1. Maintenance invariants

Do not change these unless there is a deliberate redesign:

1. Keep `CGO_ENABLED=0` for Linux amd64 builds. This is required for hosts where cgo/pthread creation is blocked by Docker/seccomp.
2. Never put rule-source credentials in the URL.
3. Keep the password in `password_file`; do not add plaintext password support to the custom YAML.
4. Reuse VictoriaMetrics `lib/promauth`; do not implement Basic Auth encoding manually.
5. Match authentication to the exact rule URL so credentials are not leaked to unrelated endpoints.
6. `-rule.auth.config` is an auth/source descriptor. It is not a normal `-rule` file.
7. Preserve normal upstream `-rule=...` behavior for local and unauthenticated sources.
8. Use immutable image tags such as `v1.151.0-custom-nocgo`; never deploy `latest` to production.

## 2. Files owned by this customization

```text
versions.env
Dockerfile
overlay/app/vmalert/rule_auth.go
overlay/app/vmalert/config/fsurl/url.go
scripts/apply-overlay.sh
scripts/upgrade-check.sh
scripts/set-version.sh
scripts/build-local.sh
scripts/smoke-basic-auth.py
.github/workflows/build-image.yml
```

### `rule_auth.go`

Adds `-rule.auth.config`, validates the YAML and creates a `promauth.BasicAuthConfig` using `username` + `password_file`.

### `config/fsurl/url.go`

Adds an exact-URL auth registry and calls `promauth.Config.SetHeaders(req, true)` before fetching authenticated rules.

### `apply-overlay.sh`

Copies the custom files into upstream source and injects `initRuleAuth()` into `app/vmalert/main.go` after logger initialization.

## 3. Start every upgrade in a branch

Example upgrade from `v1.150.0` to `v1.151.0`:

```bash
git checkout main
git pull
git checkout -b upgrade-v1.151.0
```

Do not edit the production tag in-place.

## 4. Inspect upstream compatibility first

Run:

```bash
./scripts/upgrade-check.sh v1.151.0
```

The script compares these upstream files:

```text
app/vmalert/main.go
app/vmalert/config/fsurl/url.go
lib/promauth/config.go
app/vmalert/Makefile
deployment/docker/Makefile
go.mod
```

It also checks:

- whether upstream now appears to have native rule-source authentication;
- whether `promauth.BasicAuthConfig` still exists;
- whether `BasicAuthConfig.NewConfig()` still exists;
- whether `promauth.Config.SetHeaders()` still exists;
- whether the `fsurl.FS`/`Read()` integration surface still exists;
- whether the `main.go` patch anchor used by `apply-overlay.sh` still matches.

### Stop conditions

Do not continue automatically if any of these happens:

- upstream now natively supports Basic Auth + `password_file` for `-rule` HTTP sources;
- `promauth` APIs changed;
- `app/vmalert/config/fsurl/url.go` was materially redesigned;
- the `main.go` patch anchor no longer matches;
- upstream changed HTTP rule loading to another package/client path.

In these cases, review the new upstream code and rebase the customization onto the new design instead of forcing the old overlay.

## 5. Update version metadata

After compatibility review passes:

```bash
./scripts/set-version.sh v1.151.0
```

This reads the target upstream tag and updates `versions.env` with:

```text
VM_VERSION
GO_VERSION
ROOT_IMAGE
IMAGE_SUFFIX
```

Review:

```bash
git diff -- versions.env
```

`IMAGE_SUFFIX` should normally remain:

```text
custom-nocgo
```

## 6. Review overlay against the new source

Even when `upgrade-check.sh` passes, inspect the real upstream diff:

```bash
git clone https://github.com/VictoriaMetrics/VictoriaMetrics.git /tmp/VictoriaMetrics
cd /tmp/VictoriaMetrics
git diff v1.150.0..v1.151.0 -- \
  app/vmalert/main.go \
  app/vmalert/config/fsurl/url.go \
  lib/promauth/config.go
```

Rules for merging:

- If upstream `url.go` changed, use the **new upstream file as the base** and re-apply only the minimal auth additions. Do not blindly keep an old full-file replacement.
- If the startup sequence in `main.go` changed, move `initRuleAuth()` so registration still happens before the first rule parse/read.
- If `promauth` changed, adapt the custom code to the new public API rather than copying password-reading logic into this project.

## 7. Build and run all local gates

Run:

```bash
./scripts/build-local.sh
```

It must pass all of these:

1. Docker image builds from the selected upstream tag.
2. Upstream/custom Go tests compile and pass.
3. `vmalert -version` contains the expected custom version.
4. `-rule.auth.config` exists in help output.
5. The extracted binary has no dynamic/cgo dependency.
6. A real Basic Auth HTTP server accepts the request generated from `password_file`.
7. `vmalert -dryRun` successfully parses the returned rule YAML.
8. A `docker load` tar.gz and SHA256 file are produced.

A failed gate means the upgrade is not releasable.

## 8. Test against the real rule endpoint

Use the same mount layout as production and run a dry-run before deployment:

```bash
docker run --rm \
  --network vmnet \
  -v /data/victoriametrics/victoria-metrics-config/rule:/victoria-metrics-config/rule:ro \
  -v /data/victoriametrics/victoria-metrics-secrets:/etc/victoriametrics/secrets:ro \
  vmalert-auth:v1.151.0-custom-nocgo \
  -rule.auth.config=/victoria-metrics-config/rule/rule-source.yml \
  -dryRun
```

Typical failure meanings:

| Error | Meaning |
|---|---|
| `401` | username/password_file value is wrong |
| `connection refused` / timeout | network or endpoint issue |
| `failed to parse` | remote endpoint returned invalid vmalert YAML |
| `unknown fields in config: rule` | `rule-source.yml` was incorrectly passed to `-rule=` instead of `-rule.auth.config=` |
| `runtime/cgo: pthread_create failed` | a CGO-enabled build was used; rebuild with this repository's no-cgo flow |

## 9. Commit and CI

Commit only after local checks pass:

```bash
git add .
git commit -m "upgrade vmalert auth to v1.151.0"
git push origin upgrade-v1.151.0
```

After merge to `main`, GitHub Actions must pass the same gates before the versioned image is considered releasable.

## 10. Production deployment

Use the immutable tag:

```yaml
image: ghcr.io/jionchen/vmalert-auth:v1.151.0-custom-nocgo
```

Keep:

```yaml
- "-rule.auth.config=/victoria-metrics-config/rule/rule-source.yml"
```

Do not change the runtime auth YAML format during a normal upstream upgrade.

Recreate only vmalert:

```bash
docker compose pull vmalert
docker compose up -d --no-deps --force-recreate vmalert
docker logs --tail 200 vmalert
```

## 11. Rollback

Keep the previous immutable tag available. Rollback is only an image-tag change:

```yaml
image: ghcr.io/jionchen/vmalert-auth:v1.150.0-custom-nocgo
```

Then:

```bash
docker compose up -d --no-deps --force-recreate vmalert
```

Never rely on `latest` for rollback.

## 12. Preferred long-term exit

On every upgrade, check whether upstream VictoriaMetrics has implemented authenticated HTTP rule sources with `password_file`. Once upstream provides equivalent behavior, prefer the official implementation and retire this overlay instead of maintaining a permanent fork.
