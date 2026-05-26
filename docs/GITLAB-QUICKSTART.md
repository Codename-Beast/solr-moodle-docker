# GitLab CI/CD Quick Start

Setup-Zeit: 5 Minuten.

---

## Für GitLab.com

### 1. Repository pushen

```bash
git remote add gitlab https://gitlab.com/DEIN-USERNAME/solr-moodle-docker.git
git push -u gitlab main
```

### 2. Shared Runners aktivieren

**Settings → CI/CD → Runners** → "Enable shared runners for this project"

### 3. Pipeline läuft

**Build → Pipelines** — dauert ~5-10 Minuten.

---

## Für lokale/self-hosted GitLab

### Runner-Tag konfigurieren

In GitLab: **Settings → CI/CD → Variables**

```
CI_RUNNER_TAG = docker   ← euren Runner-Namen eintragen
```

Runner `config.toml` (`/etc/gitlab-runner/config.toml`):

```toml
concurrent = 2

[[runners]]
  executor = "docker"
  clone_url = "http://host.docker.internal:8928"
  [runners.docker]
    image = "alpine:3.20"
    privileged = true
    pull_policy = "if-not-present"
    volumes = ["/var/run/docker.sock:/var/run/docker.sock", "/cache"]
    extra_hosts = ["host.docker.internal:host-gateway"]
```

---

## Was bei jedem Push getestet wird

| Stage | Dauer | Was |
|-------|-------|-----|
| lint | ~30s | docker compose config, bash -n auf alle .sh |
| test | ~5-8 min | Unit-Tests (Dateien, Permissions, Config) |

---

## Häufige Probleme

**"No runners available":**
Settings → CI/CD → Runners → Shared Runners einschalten
oder `CI_RUNNER_TAG` korrekt setzen.

**Tests schlagen fehl:**
Logs unter Build → Pipelines → Job-Name → Log.

**Pipeline zu langsam:**
5-8 Minuten ist normal (Docker-Container-Startup).

---

Mehr Details: [GITLAB-CI-CD-SETUP.md](GITLAB-CI-CD-SETUP.md)
