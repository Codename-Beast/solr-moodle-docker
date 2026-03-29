# GitLab CI/CD Setup Guide

**Autor:** BSC Bernd Schreistetter | **Eledia GmbH**

Vollstaendige Anleitung fuer die GitLab CI/CD Pipeline.

---

## Pipeline-Struktur

```
VALIDATE  →  BUILD  →  TEST  →  SECURITY  →  CLEANUP
(Syntax)    (Images)  (parallel)  (Perms)    (manuell)
```

Dauert ca. 8-10 Minuten je nach Runner.

---

## Voraussetzungen

### GitLab.com (SaaS)
- GitLab.com Account
- Shared Runner (automatisch da)
- Git Repository

### Self-Hosted
- GitLab CE/EE 15.0+
- GitLab Runner installiert
- Docker auf dem Runner
- Mindestens 4 GB RAM

---

## GitLab-Einrichtung

### 1. Repository pushen

```bash
git remote add gitlab https://gitlab.com/DEIN-USERNAME/solr-moodle-docker.git
git push -u gitlab main
```

Oder bestehendes Remote aendern:

```bash
git remote set-url origin https://gitlab.com/DEIN-USERNAME/solr-moodle-docker.git
git push -u origin main
```

### 2. CI/CD ist automatisch aktiv

Sobald `.gitlab-ci.yml` im Repo liegt, laeuft die Pipeline. Pruefen unter **Build → Pipelines**.

### 3. Runner waehlen

**Option A: Shared Runners (GitLab.com)** — fuer den Anfang

- Kostenlos (400 CI/CD Minuten/Monat)
- Keine Konfiguration noetig
- **Settings → CI/CD → Runners** → "Enable shared runners" einschalten

**Option B: Self-Hosted Runner** — fuer Produktiv

- Keine Minuten-Limits
- Schneller (eigene Hardware)
- Setup siehe unten

---

## Pipeline-Stages

### Stage 1: VALIDATE (~30 Sekunden)

Prueft `docker-compose.yml` Syntax, Datei-Existenz, Verzeichnisstruktur.

### Stage 2: BUILD (1-2 Minuten)

Baut den Init-Container. Docker Images werden gecacht.

### Stage 3: TEST (6-8 Minuten, parallel)

Drei Jobs laufen gleichzeitig:
- **test:unit** (~1 min) — Dateistruktur, Permissions, Git-Sicherheit
- **test:integration** (3-5 min) — Container-Startup, Health-Checks, Auth, Passwort-Erkennung
- **test:moodle-documents** (3-5 min) — 7 Dokumente indexieren, Queries, Highlighting, Faceting

### Stage 4: SECURITY (~1 Minute)

- Container-Privileges, Netzwerk-Binding, File-Permissions
- Sucht nach `.env` in Git, prueft `.gitignore`, hardcoded Passwords

### Stage 5: CLEANUP (manuell)

Docker Images, Container, Volumes aufraeumen. Nur per Button in der Pipeline.

---

## Runner-Konfiguration (Self-Hosted)

### Runner installieren

**Ubuntu/Debian:**
```bash
curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | sudo bash
sudo apt-get install gitlab-runner
gitlab-runner --version
```

**Fedora/RHEL:**
```bash
curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.rpm.sh" | sudo bash
sudo dnf install gitlab-runner
gitlab-runner --version
```

### Runner registrieren

In GitLab: **Settings → CI/CD → Runners → New project runner** → Token kopieren.

```bash
sudo gitlab-runner register
```

Eingaben:
```
GitLab instance URL: https://gitlab.com/  (oder Self-Hosted URL)
Registration token:  [TOKEN aus WebUI]
Description:         docker-runner-solr
Tags:                docker,solr,testing
Executor:            docker
Default Docker image: docker:27.0.7
```

### Runner konfigurieren

`/etc/gitlab-runner/config.toml`:

```toml
concurrent = 2

[[runners]]
  name = "docker-runner-solr"
  url = "https://gitlab.com/"
  token = "YOUR_TOKEN"
  executor = "docker"

  [runners.docker]
    image = "docker:27.0.7"
    privileged = true  # noetig fuer Docker-in-Docker
    volumes = ["/cache", "/var/run/docker.sock:/var/run/docker.sock"]
    pull_policy = ["if-not-present"]

  [runners.cache]
    Type = "local"
    Path = "/var/lib/gitlab-runner/cache"
    Shared = true
```

### Starten und pruefen

```bash
sudo gitlab-runner restart
sudo gitlab-runner status
# Debug: sudo gitlab-runner --debug run
```

In GitLab unter **Settings → CI/CD → Runners** sollte der Runner mit gruenem Punkt erscheinen.

---

## Variables & Secrets

Die Pipeline braucht **keine manuell konfigurierten Variables** — `.env` wird im Setup-Job generiert, Passwoerter zur Laufzeit.

Falls du trotzdem welche brauchst (**Settings → CI/CD → Variables → Add Variable**):

| Key | Value | Protected | Masked |
|-----|-------|-----------|--------|
| `SOLR_VERSION` | `9.10.1` | nein | nein |
| `SOLR_HEAP` | `2g` | nein | nein |
| `INSTANCE_NAME` | `test` | nein | nein |

```yaml
variables:
  SOLR_VERSION: ${SOLR_VERSION:-9.10.1}
  SOLR_HEAP: ${SOLR_HEAP:-2g}
```

---

## Pipeline ausfuehren

### Automatisch

Laeuft bei Push auf `main`/`develop` und bei Merge Requests.

### Manuell

**Build → Pipelines → Run Pipeline** → Branch waehlen → Run.

### Status

Unter **Build → Pipelines** auf die Pipeline-ID klicken. Job-Logs per Klick auf den Job-Namen.

---

## Troubleshooting

### "No runners available"

Shared Runners einschalten: **Settings → CI/CD → Runners → Enable shared runners**.

Oder Self-Hosted Runner registrieren (siehe oben).

### "Cannot connect to Docker daemon"

In `/etc/gitlab-runner/config.toml`:
```toml
[runners.docker]
  privileged = true
  volumes = ["/var/run/docker.sock:/var/run/docker.sock"]
```
Dann `sudo gitlab-runner restart`.

### Permission Denied (Docker Socket)

```bash
sudo usermod -aG docker gitlab-runner
sudo systemctl restart gitlab-runner
```

### Timeout

In `.gitlab-ci.yml` Timeout erhoehen:
```yaml
test:integration:
  timeout: 15 minutes
```

### "docker compose: command not found"

In `.gitlab-ci.yml`:
```yaml
before_script:
  - apk add --no-cache docker-compose
```

---

## Best Practices

**Caching:**
```yaml
test:integration:
  cache:
    key: ${CI_COMMIT_REF_SLUG}
    paths:
      - .env
      - docker-images/
```

**Nur relevante Branches:**
```yaml
rules:
  - if: '$CI_MERGE_REQUEST_ID'
  - if: '$CI_COMMIT_BRANCH == "main"'
  - if: '$CI_COMMIT_TAG'
```

**Protected Branches:** Settings → Repository → Protected Branches: `main` nur Maintainer.

**Pipeline Badge im README:**
```markdown
[![Pipeline Status](https://gitlab.com/DEIN-USERNAME/solr-moodle-docker/badges/main/pipeline.svg)](https://gitlab.com/DEIN-USERNAME/solr-moodle-docker/-/pipelines)
```

---

## Checkliste

- [ ] `.gitlab-ci.yml` committed
- [ ] Projekt auf GitLab gepusht
- [ ] Shared Runners aktiv oder Self-Hosted Runner registriert
- [ ] Erste Pipeline erfolgreich
- [ ] Pipeline Badge im README
- [ ] Protected Branches konfiguriert

---

## Links

- [GitLab CI/CD Basics](https://docs.gitlab.com/ee/ci/)
- [.gitlab-ci.yml Reference](https://docs.gitlab.com/ee/ci/yaml/)
- [GitLab Runner Installation](https://docs.gitlab.com/runner/install/)
- [Docker-in-Docker](https://docs.gitlab.com/ee/ci/docker/using_docker_build.html)
- [README.md](../README.md)
- [CHANGELOG.md](../CHANGELOG.md)

---

**Support:** [GitHub Issues](https://github.com/Codename-Beast/solr-moodle-docker/issues) | BSC Bernd Schreistetter | Eledia.de
