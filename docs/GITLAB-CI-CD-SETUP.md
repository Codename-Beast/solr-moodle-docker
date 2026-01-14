# GitLab CI/CD Setup Guide

**Version:** v2.1
**Autor:** BSC Bernd Schreistetter
**Company:** Eledia.de

Vollständige Anleitung zur Einrichtung der GitLab CI/CD Pipeline für Solr-Moodle-Docker.

---

## 📋 Inhaltsverzeichnis

1. [Überblick](#überblick)
2. [Voraussetzungen](#voraussetzungen)
3. [GitLab-Einrichtung](#gitlab-einrichtung)
4. [Pipeline-Stages](#pipeline-stages)
5. [Runner-Konfiguration](#runner-konfiguration)
6. [Variables & Secrets](#variables--secrets)
7. [Pipeline ausführen](#pipeline-ausführen)
8. [Troubleshooting](#troubleshooting)
9. [Best Practices](#best-practices)

---

## 🎯 Überblick

Die CI/CD Pipeline testet automatisch:
- ✅ Docker Compose Syntax-Validierung
- ✅ Container Build-Tests
- ✅ Unit Tests (Dateistruktur, Permissions)
- ✅ Integration Tests (Container-Startup, Health-Checks)
- ✅ Moodle Document Tests (Indexierung, Queries)
- ✅ Security Tests (Secrets, Permissions, Authentication)
- ✅ Secret Scanning (verhindert versehentliche Commits)

### Pipeline-Struktur

```
┌─────────────┐
│  VALIDATE   │  Syntax & Struktur
└──────┬──────┘
       │
┌──────▼──────┐
│    BUILD    │  Container Images
└──────┬──────┘
       │
┌──────▼──────┐
│    TEST     │  Unit, Integration, Moodle Tests (parallel)
└──────┬──────┘
       │
┌──────▼──────┐
│  SECURITY   │  Security Tests & Secret Scanning
└──────┬──────┘
       │
┌──────▼──────┐
│  CLEANUP    │  Optional: Docker Cleanup
└─────────────┘
```

**Pipeline-Dauer:** Ca. 8-12 Minuten (je nach Runner-Performance)

---

## 🔧 Voraussetzungen

### Auf GitLab.com (SaaS)
- ✅ GitLab.com Account
- ✅ Shared Runner (automatisch verfügbar)
- ✅ Projekt mit Git Repository

### Self-Hosted GitLab
- ✅ GitLab CE/EE Version 15.0+
- ✅ GitLab Runner installiert
- ✅ Docker auf Runner-Server installiert
- ✅ Mindestens 4 GB RAM auf Runner

---

## 🚀 GitLab-Einrichtung

### Schritt 1: Repository zu GitLab pushen

Wenn dein Projekt noch nicht auf GitLab ist:

```bash
# 1. GitLab-Projekt erstellen (über WebUI)
# 2. Remote hinzufügen
git remote add gitlab https://gitlab.com/DEIN-USERNAME/solr-moodle-docker.git

# 3. Pushen
git push -u gitlab main
```

**Oder bestehendes Remote ändern:**

```bash
# GitHub Remote durch GitLab ersetzen
git remote set-url origin https://gitlab.com/DEIN-USERNAME/solr-moodle-docker.git
git push -u origin main
```

### Schritt 2: GitLab CI/CD aktivieren

Die Pipeline wird **automatisch aktiviert**, sobald `.gitlab-ci.yml` im Repository ist.

Überprüfen:
1. Gehe zu deinem Projekt auf GitLab
2. **Build → Pipelines** im Menü
3. Du solltest eine Pipeline sehen (nach dem ersten Push)

![GitLab Pipelines](https://docs.gitlab.com/ee/ci/img/pipelines_index_v13_6.png)

### Schritt 3: Runner-Typ wählen

GitLab bietet zwei Runner-Typen:

#### Option A: Shared Runners (GitLab.com) ✅ Empfohlen für Start

**Vorteile:**
- ✅ Kostenlos (2000 CI/CD Minuten/Monat)
- ✅ Keine Konfiguration nötig
- ✅ Automatisch verfügbar

**Aktivierung:**
1. **Settings → CI/CD → Runners**
2. Stelle sicher, dass "Enable shared runners for this project" aktiviert ist

![Enable Shared Runners](https://docs.gitlab.com/ee/ci/img/shared_runners_v14_5.png)

#### Option B: Self-Hosted Runner (für Firmen) 🏢

**Vorteile:**
- ✅ Keine Pipeline-Minuten-Limits
- ✅ Schnellere Builds (eigene Hardware)
- ✅ Volle Kontrolle

**Installation:** Siehe [Runner-Konfiguration](#runner-konfiguration) weiter unten.

---

## 📊 Pipeline-Stages im Detail

### Stage 1: VALIDATE (30 Sekunden)

**Was wird getestet:**
- ✅ `docker-compose.yml` Syntax
- ✅ Existenz aller Dateien (Dockerfile, Configs)
- ✅ Verzeichnisstruktur

**Wann läuft es:**
- Bei Merge Requests
- Bei Push auf `main`, `develop`, `claude/*` Branches

### Stage 2: BUILD (1-2 Minuten)

**Was wird gebaut:**
- ✅ Init-Container (`Dockerfile`)
- ✅ Docker Image Caching

**Artefakte:**
- Docker Images werden für spätere Stages gecacht

### Stage 3: TEST (6-8 Minuten)

**Jobs laufen parallel:**

1. **test:unit** (1 Minute)
   - Dateistruktur
   - Permissions
   - Git-Sicherheit

2. **test:integration** (3-4 Minuten)
   - Container-Startup
   - Health-Checks
   - Authentication
   - Password-Change-Detection

3. **test:moodle-documents** (2-3 Minuten)
   - 7 Moodle-Dokumente indexieren
   - Query-Tests (einfach, phrase, wildcard)
   - Highlighting
   - Faceting
   - Sorting

### Stage 4: SECURITY (2 Minuten)

**Jobs:**

1. **security:tests**
   - Container-Privileges
   - Netzwerk-Binding
   - File-Permissions

2. **security:secrets-scan**
   - Sucht nach `.env` in Git
   - Prüft `.gitignore`
   - Sucht nach hardcoded Passwords

### Stage 5: CLEANUP (manuell)

**Was wird bereinigt:**
- Docker Images
- Container
- Volumes

**Wann:** Nur bei manueller Ausführung (Button in Pipeline)

---

## 🏃 Runner-Konfiguration (Self-Hosted)

### Für Self-Hosted GitLab Runner

#### Schritt 1: Runner installieren

**Auf Ubuntu/Debian:**

```bash
# 1. Repository hinzufügen
curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | sudo bash

# 2. Runner installieren
sudo apt-get install gitlab-runner

# 3. Verifizieren
gitlab-runner --version
```

**Auf Fedora/RHEL:**

```bash
# 1. Repository hinzufügen
curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.rpm.sh" | sudo bash

# 2. Runner installieren
sudo dnf install gitlab-runner

# 3. Verifizieren
gitlab-runner --version
```

#### Schritt 2: Runner registrieren

1. **Gehe zu GitLab:**
   - **Settings → CI/CD → Runners**
   - Klicke auf **"New project runner"**
   - Kopiere das **Registration Token**

2. **Registriere den Runner:**

```bash
sudo gitlab-runner register
```

**Antworten auf Prompts:**

```
Enter GitLab instance URL:
→ https://gitlab.com/  (oder deine Self-Hosted URL)

Enter registration token:
→ [TOKEN von GitLab WebUI]

Enter description for runner:
→ docker-runner-solr

Enter tags (comma separated):
→ docker,solr,testing

Enter executor:
→ docker

Enter default Docker image:
→ docker:24.0.7
```

#### Schritt 3: Runner konfigurieren

Editiere `/etc/gitlab-runner/config.toml`:

```toml
concurrent = 2  # Anzahl paralleler Jobs

[[runners]]
  name = "docker-runner-solr"
  url = "https://gitlab.com/"
  token = "YOUR_TOKEN"
  executor = "docker"

  [runners.docker]
    image = "docker:24.0.7"
    privileged = true  # Wichtig für Docker-in-Docker!
    volumes = ["/cache", "/var/run/docker.sock:/var/run/docker.sock"]
    pull_policy = ["if-not-present"]

  [runners.cache]
    Type = "local"
    Path = "/var/lib/gitlab-runner/cache"
    Shared = true
```

#### Schritt 4: Runner starten

```bash
# Restart Runner
sudo gitlab-runner restart

# Status prüfen
sudo gitlab-runner status

# Logs ansehen
sudo gitlab-runner --debug run
```

#### Schritt 5: Verifizieren

Gehe zu **Settings → CI/CD → Runners** in GitLab:
- Runner sollte **grünen Punkt** haben (online)
- Tags sollten angezeigt werden

---

## 🔐 Variables & Secrets

### Keine Secrets benötigt! 🎉

Diese Pipeline benötigt **keine manuell konfigurierten Variables**, da:
- ✅ `.env` wird automatisch generiert (im Setup-Job)
- ✅ Passwörter werden zur Laufzeit generiert
- ✅ Alle Tests laufen in isolierten Containern

### Optional: Custom Variables

Falls du spezifische Einstellungen brauchst:

1. **Settings → CI/CD → Variables**
2. Klicke **"Add Variable"**

**Beispiel-Variables:**

| Key | Value | Protected | Masked |
|-----|-------|-----------|--------|
| `SOLR_VERSION` | `9.10.0` | ❌ | ❌ |
| `SOLR_HEAP` | `4g` | ❌ | ❌ |
| `INSTANCE_NAME` | `test` | ❌ | ❌ |

**Verwendung in `.gitlab-ci.yml`:**

```yaml
variables:
  SOLR_VERSION: ${SOLR_VERSION:-9.10.0}
  SOLR_HEAP: ${SOLR_HEAP:-2g}
```

---

## ▶️ Pipeline ausführen

### Automatische Ausführung

Pipeline startet automatisch bei:
- ✅ Push auf `main`, `develop`, `claude/*` Branches
- ✅ Merge Requests

### Manuelle Ausführung

1. **Gehe zu Build → Pipelines**
2. Klicke **"Run Pipeline"**
3. Wähle Branch
4. Klicke **"Run Pipeline"**

![Run Pipeline](https://docs.gitlab.com/ee/ci/img/run_pipeline_v14_2.png)

### Pipeline Status ansehen

**Live-Ansicht:**
1. **Build → Pipelines**
2. Klicke auf Pipeline-ID (z.B. `#123`)
3. Siehst du alle Jobs mit Status:
   - 🟢 **Passed** - Erfolgreich
   - 🔴 **Failed** - Fehler
   - 🟡 **Running** - Läuft gerade
   - ⚪ **Pending** - Wartet

**Job-Logs ansehen:**
1. Klicke auf Job-Namen (z.B. `test:integration`)
2. Siehst du Live-Logs
3. Kannst Logs herunterladen (Button rechts oben)

---

## 🐛 Troubleshooting

### Problem 1: "No runners available"

**Symptom:**
```
This job is stuck because you don't have any active runners
```

**Lösung:**

**Option A: Shared Runners aktivieren**
```
Settings → CI/CD → Runners → Enable shared runners for this project
```

**Option B: Self-Hosted Runner hinzufügen**
Siehe [Runner-Konfiguration](#runner-konfiguration)

---

### Problem 2: "Cannot connect to Docker daemon"

**Symptom:**
```
docker: Cannot connect to the Docker daemon at unix:///var/run/docker.sock
```

**Lösung:**

Editiere `/etc/gitlab-runner/config.toml`:

```toml
[runners.docker]
  privileged = true  # Muss true sein!
  volumes = ["/var/run/docker.sock:/var/run/docker.sock"]
```

Dann:
```bash
sudo gitlab-runner restart
```

---

### Problem 3: Tests schlagen fehl (Permission Denied)

**Symptom:**
```
permission denied while trying to connect to the Docker daemon socket
```

**Lösung:**

Runner-User zu Docker-Gruppe hinzufügen:

```bash
sudo usermod -aG docker gitlab-runner
sudo systemctl restart gitlab-runner
```

---

### Problem 4: Pipeline läuft zu lange (Timeout)

**Symptom:**
```
Job's log exceeded limit of 4194304 bytes.
```

**Lösung 1: Timeout erhöhen**

In `.gitlab-ci.yml`:
```yaml
test:integration:
  timeout: 15 minutes  # Statt default 1 hour
```

**Lösung 2: Logs reduzieren**

```yaml
script:
  - docker compose up -d > /dev/null 2>&1
```

---

### Problem 5: "docker compose: command not found"

**Symptom:**
```
/bin/sh: docker-compose: not found
```

**Lösung:**

In `.gitlab-ci.yml` before_script:
```yaml
before_script:
  - apk add --no-cache docker-compose  # oder docker-cli-compose
```

---

## 📋 Best Practices

### 1. Pipeline-Geschwindigkeit optimieren

**Caching nutzen:**

```yaml
test:integration:
  cache:
    key: ${CI_COMMIT_REF_SLUG}
    paths:
      - .env
      - docker-images/
```

**Parallele Jobs:**
- Unit, Integration und Moodle Tests laufen parallel
- Spart 60% Zeit

### 2. Nur relevante Branches testen

```yaml
rules:
  - if: '$CI_MERGE_REQUEST_ID'  # Nur bei MRs
  - if: '$CI_COMMIT_BRANCH == "main"'  # Nur main
  - if: '$CI_COMMIT_TAG'  # Nur bei Tags
```

### 3. Protected Branches

**Settings → Repository → Protected Branches:**
- `main` → Nur Maintainer dürfen pushen
- Require pipeline to succeed before merging

### 4. Merge Request Approvals

**Settings → Merge Requests → Merge request approvals:**
- Mindestens 1 Approval erforderlich
- Pipeline muss erfolgreich sein

### 5. Pipeline Badges

Zeige Pipeline-Status im README:

**Markdown für README.md:**
```markdown
[![Pipeline Status](https://gitlab.com/DEIN-USERNAME/solr-moodle-docker/badges/main/pipeline.svg)](https://gitlab.com/DEIN-USERNAME/solr-moodle-docker/-/pipelines)
```

**Resultat:**
![Pipeline Status](https://gitlab.com/DEIN-USERNAME/solr-moodle-docker/badges/main/pipeline.svg)

---

## 🎓 Weiterführende Ressourcen

### Offizielle GitLab Dokumentation
- [GitLab CI/CD Basics](https://docs.gitlab.com/ee/ci/)
- [.gitlab-ci.yml Reference](https://docs.gitlab.com/ee/ci/yaml/)
- [GitLab Runner Installation](https://docs.gitlab.com/runner/install/)
- [Docker-in-Docker](https://docs.gitlab.com/ee/ci/docker/using_docker_build.html)

### Solr-Moodle-Docker spezifisch
- [README.md](../README.md) - Projekt-Dokumentation
- [CHANGELOG.md](../CHANGELOG.md) - Versionshistorie
- [scripts/run-tests.sh](../scripts/run-tests.sh) - Test-Suite

---

## 📞 Support

**Bei Fragen oder Problemen:**
- GitHub Issues: [solr-moodle-docker/issues](https://github.com/Codename-Beast/solr-moodle-docker/issues)
- Developer: BSC Bernd Schreistetter
- Company: Eledia.de

---

## ✅ Checkliste: Pipeline erfolgreich eingerichtet

- [ ] `.gitlab-ci.yml` im Repository committed
- [ ] Projekt auf GitLab gepusht
- [ ] Shared Runners aktiviert ODER Self-Hosted Runner registriert
- [ ] Erste Pipeline erfolgreich durchgelaufen
- [ ] Pipeline Badge im README hinzugefügt
- [ ] Protected Branches konfiguriert
- [ ] Merge Request Approvals aktiviert

**Wenn alle Punkte ✅ sind: Herzlichen Glückwunsch! CI/CD ist einsatzbereit! 🎉**
