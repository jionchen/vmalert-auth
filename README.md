# vmalert-auth

Custom VictoriaMetrics `vmalert` image based on `v1.150.0` with authenticated HTTP rule source support for:

```yaml
rule:
  url: https://alertfusion.xxx/api/vmalert/rules
  basic_auth:
    username: vmalert
    password_file: /etc/vmalert/secrets/password
```

The implementation reuses VictoriaMetrics `lib/promauth`. The password is read via `password_file`, is not passed on the command line, and password rotation is picked up by `promauth` without restarting vmalert.

## Image

GitHub Actions publishes:

```text
ghcr.io/jionchen/vmalert-auth:v1.150.0-custom
```

and also creates a `docker load` artifact:

```text
vmalert-auth-v1.150.0-custom-linux-amd64.tar.gz
```

## Run

Create the password file:

```bash
mkdir -p /etc/vmalert/secrets
printf '%s' 'your-password' > /etc/vmalert/secrets/password
chmod 600 /etc/vmalert/secrets/password
```

Create `/etc/vmalert/rule-source.yml`:

```yaml
rule:
  url: https://alertfusion.xxx/api/vmalert/rules
  basic_auth:
    username: vmalert
    password_file: /etc/vmalert/secrets/password
```

Example Docker run:

```bash
docker run --rm \
  -p 8880:8880 \
  -v /etc/vmalert/rule-source.yml:/etc/vmalert/rule-source.yml:ro \
  -v /etc/vmalert/secrets/password:/etc/vmalert/secrets/password:ro \
  ghcr.io/jionchen/vmalert-auth:v1.150.0-custom \
  -rule.auth.config=/etc/vmalert/rule-source.yml \
  -datasource.url=http://victoriametrics:8428 \
  -notifier.url=http://alertmanager:9093 \
  -configCheckInterval=30s
```

## Load offline image

```bash
gunzip vmalert-auth-v1.150.0-custom-linux-amd64.tar.gz
docker load -i vmalert-auth-v1.150.0-custom-linux-amd64.tar
```

## Compatibility

Existing `-rule=/path/to/rules.yml` and public `-rule=https://...` behavior is preserved. `-rule.auth.config` adds one authenticated HTTP(S) rule source and can be used together with existing `-rule` flags.
