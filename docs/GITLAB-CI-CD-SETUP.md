# GitLab CI/CD Setup Guide

**Autor:** BSC Bernd Schreistetter | **Eledia GmbH**

---

## Pipeline-Struktur

```
lint → test
```

| Stage | Jobs | Dauer |
|-------|------|-------|
| lint | main-minimal (main), feature-lint (feature/release) | ~30s |
| test | feature-full-test | ~5-8 min |

---

## Voraussetzungen

### GitLab.com (SaaS)
- GitLab.com Account mit Shared Runners

### Self-Hosted
- GitLab CE/EE 16.0+
- GitLab Runner mit Docker-Executor
- Docker auf dem Runner-Host
- Mindestens 4 GB RAM

---

## Runner konfigurieren

### Runner-Tag setzen

In GitLab: **Settings → CI/CD → Variables → Add Variable**

```
Key:   CI_RUNNER_TAG
Value: <euer Runner-Name>   # z.B. xen-04, docker-runner, ...
```

Default (lokal): `docker`

### config.toml

```toml
concurrent = 2

[[runners]]
  name = "euer-runner"
  url = "http://gitlab.example.com"
  executor = "docker"
  clone_url = "http://host.docker.internal:8928"  # bei lokalem GitLab
  [runners.docker]
    image = "alpine:3.20"
    privileged = true
    pull_policy = "if-not-present"
    volumes = ["/var/run/docker.sock:/var/run/docker.sock", "/cache"]
    extra_hosts = ["host.docker.internal:host-gateway"]
```

---

## Troubleshooting

**"No runners available":**
Settings → CI/CD → Runners → Shared Runners einschalten,
oder `CI_RUNNER_TAG` korrekt setzen.

**"Cannot connect to Docker daemon":**
```toml
[runners.docker]
  privileged = true
  volumes = ["/var/run/docker.sock:/var/run/docker.sock"]
```

**Timeout (10 Minuten):**
Die GitLab CI führt die SolrCloud-Suite mit `--cloud --no-performance --no-cleanup` aus. Performance-/Lasttests sind im 10-Minuten-Fenster bewusst deaktiviert; vollständige Läufe inklusive Performance laufen lokal.

**"docker compose: command not found":**
```yaml
before_script:
  - apk add --no-cache docker-cli docker-cli-compose
```

---

## Checkliste

- [ ] `.gitlab-ci.yml` committed und gepusht
- [ ] `CI_RUNNER_TAG` Variable gesetzt
- [ ] Erste Pipeline erfolgreich
- [ ] `config.toml` mit `pull_policy = if-not-present`

---

## Links

- [GitLab CI/CD Docs](https://docs.gitlab.com/ee/ci/)
- [GitLab Runner Installation](https://docs.gitlab.com/runner/install/)
- [.gitlab-ci.yml Reference](https://docs.gitlab.com/ee/ci/yaml/)
- [README.md](../README.md)
- [CHANGELOG.md](../CHANGELOG.md)
