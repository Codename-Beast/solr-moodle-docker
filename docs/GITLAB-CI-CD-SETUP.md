# GitLab CI/CD Setup Guide

**Version:** v.
**Autor:** BSC Bernd Schreistetter
**Company:** Eledia.de

Vollständige Anleitung zur Einrichtung der GitLab CI/CD Pipeline für Solr-Moodle-Docker.

---

##  Inhaltsverzeichnis

. [Überblick](#überblick)
. [Voraussetzungen](#voraussetzungen)
. [GitLab-Einrichtung](#gitlab-einrichtung)
. [Pipeline-Stages](#pipeline-stages)
5. [Runner-Konfiguration](#runner-konfiguration)
6. [Variables & Secrets](#variables--secrets)
7. [Pipeline ausführen](#pipeline-ausführen)
8. [Troubleshooting](#troubleshooting)
9. [Best Practices](#best-practices)

---

##  Überblick

Die CI/CD Pipeline testet automatisch:
-  Docker Compose Syntax-Validierung
-  Container Build-Tests
-  Unit Tests (Dateistruktur, Permissions)
-  Integration Tests (Container-Startup, Health-Checks)
-  Moodle Document Tests (Indexierung, Queries)
-  Security Tests (Secrets, Permissions, Authentication)
-  Secret Scanning (verhindert versehentliche Commits)

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

**Pipeline-Dauer:** Ca. 8- Minuten (je nach Runner-Performance)

---

##  Voraussetzungen

### Auf GitLab.com (SaaS)
-  GitLab.com Account
-  Shared Runner (automatisch verfügbar)
-  Projekt mit Git Repository

### Self-Hosted GitLab
-  GitLab CE/EE Version 5.0+
-  GitLab Runner installiert
-  Docker auf Runner-Server installiert
-  Mindestens  GB RAM auf Runner

---

##  GitLab-Einrichtung

### Schritt : Repository zu GitLab pushen

Wenn dein Projekt noch nicht auf GitLab ist:

```bash
# . GitLab-Projekt erstellen (über WebUI)
# . Remote hinzufügen
git remote add gitlab https://gitlab.com/DEIN-USERNAME/solr-moodle-docker.git

# . Pushen
git push -u gitlab main
```

**Oder bestehendes Remote ändern:**

```bash
# GitHub Remote durch GitLab ersetzen
git remote set-url origin https://gitlab.com/DEIN-USERNAME/solr-moodle-docker.git
git push -u origin main
```

### Schritt : GitLab CI/CD aktivieren

Die Pipeline wird **automatisch aktiviert**, sobald `.gitlab-ci.yml` im Repository ist.

Überprüfen:
. Gehe zu deinem Projekt auf GitLab
. **Build → Pipelines** im Menü
. Du solltest eine Pipeline sehen (nach dem ersten Push)

![GitLab Pipelines](https://docs.gitlab.com/ee/ci/img/pipelines_index_v_6.png)

### Schritt : Runner-Typ wählen

GitLab bietet zwei Runner-Typen:

#### Option A: Shared Runners (GitLab.com)  Empfohlen für Start

**Vorteile:**
-  Kostenlos (000 CI/CD Minuten/Monat)
-  Keine Konfiguration nötig
-  Automatisch verfügbar

**Aktivierung:**
. **Settings → CI/CD → Runners**
. Stelle sicher, dass "Enable shared runners for this project" aktiviert ist

![Enable Shared Runners](https://docs.gitlab.com/ee/ci/img/shared_runners_v_5.png)

#### Option B: Self-Hosted Runner (für Firmen) 🏢

**Vorteile:**
-  Keine Pipeline-Minuten-Limits
-  Schnellere Builds (eigene Hardware)
-  Volle Kontrolle

**Installation:** Siehe [Runner-Konfiguration](#runner-konfiguration) weiter unten.

---

##  Pipeline-Stages im Detail

### Stage : VALIDATE (0 Sekunden)

**Was wird getestet:**
-  `docker-compose.yml` Syntax
-  Existenz aller Dateien (Dockerfile, Configs)
-  Verzeichnisstruktur

**Wann läuft es:**
- Bei Merge Requests
- Bei Push auf `main`, `master` oder `develop` Branches

### Stage : BUILD (- Minuten)

**Was wird gebaut:**
-  Init-Container (`Dockerfile`)
-  Docker Image Caching

**Artefakte:**
- Docker Images werden für spätere Stages gecacht

### Stage : TEST (6-8 Minuten)

**Jobs laufen parallel:**

. **test:unit** ( Minute)
   - Dateistruktur
   - Permissions
   - Git-Sicherheit

. **test:integration** (- Minuten)
   - Container-Startup
   - Health-Checks
   - Authentication
   - Password-Change-Detection

. **test:moodle-documents** (- Minuten)
   - 7 Moodle-Dokumente indexieren
   - Query-Tests (einfach, phrase, wildcard)
   - Highlighting
   - Faceting
   - Sorting

### Stage : SECURITY ( Minuten)

**Jobs:**

. **security:tests**
   - Container-Privileges
   - Netzwerk-Binding
   - File-Permissions

. **security:secrets-scan**
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

#### Schritt : Runner installieren

**Auf Ubuntu/Debian:**

```bash
# . Repository hinzufügen
curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | sudo bash

# . Runner installieren
sudo apt-get install gitlab-runner

# . Verifizieren
gitlab-runner --version
```

**Auf Fedora/RHEL:**

```bash
# . Repository hinzufügen
curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.rpm.sh" | sudo bash

# . Runner installieren
sudo dnf install gitlab-runner

# . Verifizieren
gitlab-runner --version
```

#### Schritt : Runner registrieren

. **Gehe zu GitLab:**
   - **Settings → CI/CD → Runners**
   - Klicke auf **"New project runner"**
   - Kopiere das **Registration Token**

. **Registriere den Runner:**

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
→ docker:.0.7
```

#### Schritt : Runner konfigurieren

Editiere `/etc/gitlab-runner/config.toml`:

```toml
concurrent =   # Anzahl paralleler Jobs

[[runners]]
  name = "docker-runner-solr"
  url = "https://gitlab.com/"
  token = "YOUR_TOKEN"
  executor = "docker"

  [runners.docker]
    image = "docker:.0.7"
    privileged = true  # Wichtig für Docker-in-Docker!
    volumes = ["/cache", "/var/run/docker.sock:/var/run/docker.sock"]
    pull_policy = ["if-not-present"]

  [runners.cache]
    Type = "local"
    Path = "/var/lib/gitlab-runner/cache"
    Shared = true
```

#### Schritt : Runner starten

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
-  `.env` wird automatisch generiert (im Setup-Job)
-  Passwörter werden zur Laufzeit generiert
-  Alle Tests laufen in isolierten Containern

### Optional: Custom Variables

Falls du spezifische Einstellungen brauchst:

. **Settings → CI/CD → Variables**
. Klicke **"Add Variable"**

**Beispiel-Variables:**

| Key | Value | Protected | Masked |
|-----|-------|-----------|--------|
| `SOLR_VERSION` | `9.0.0` |  |  |
| `SOLR_HEAP` | `g` |  |  |
| `INSTANCE_NAME` | `test` |  |  |

**Verwendung in `.gitlab-ci.yml`:**

```yaml
variables:
  SOLR_VERSION: ${SOLR_VERSION:-9.0.0}
  SOLR_HEAP: ${SOLR_HEAP:-g}
```

---

## ▶ Pipeline ausführen

### Automatische Ausführung

Pipeline startet automatisch bei:
-  Push auf `main`, `master` oder `develop` Branches
-  Merge Requests

### Manuelle Ausführung

. **Gehe zu Build → Pipelines**
. Klicke **"Run Pipeline"**
. Wähle Branch
. Klicke **"Run Pipeline"**

![Run Pipeline](https://docs.gitlab.com/ee/ci/img/run_pipeline_v_.png)

### Pipeline Status ansehen

**Live-Ansicht:**
. **Build → Pipelines**
. Klicke auf Pipeline-ID (z.B. `#`)
. Siehst du alle Jobs mit Status:
   - 🟢 **Passed** - Erfolgreich
   - 🔴 **Failed** - Fehler
   - 🟡 **Running** - Läuft gerade
   - ⚪ **Pending** - Wartet

**Job-Logs ansehen:**
. Klicke auf Job-Namen (z.B. `test:integration`)
. Siehst du Live-Logs
. Kannst Logs herunterladen (Button rechts oben)

---

## 🐛 Troubleshooting

### Problem : "No runners available"

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

### Problem : "Cannot connect to Docker daemon"

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

### Problem : Tests schlagen fehl (Permission Denied)

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

### Problem : Pipeline läuft zu lange (Timeout)

**Symptom:**
```
Job's log exceeded limit of 90 bytes.
```

**Lösung : Timeout erhöhen**

In `.gitlab-ci.yml`:
```yaml
test:integration:
  timeout: 5 minutes  # Statt default  hour
```

**Lösung : Logs reduzieren**

```yaml
script:
  - docker compose up -d > /dev/null >&
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

##  Best Practices

### . Pipeline-Geschwindigkeit optimieren

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

### . Nur relevante Branches testen

```yaml
rules:
  - if: '$CI_MERGE_REQUEST_ID'  # Nur bei MRs
  - if: '$CI_COMMIT_BRANCH == "main"'  # Nur main
  - if: '$CI_COMMIT_TAG'  # Nur bei Tags
```

### . Protected Branches

**Settings → Repository → Protected Branches:**
- `main` → Nur Maintainer dürfen pushen
- Require pipeline to succeed before merging

### . Merge Request Approvals

**Settings → Merge Requests → Merge request approvals:**
- Mindestens  Approval erforderlich
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

##  Checkliste: Pipeline erfolgreich eingerichtet

- [ ] `.gitlab-ci.yml` im Repository committed
- [ ] Projekt auf GitLab gepusht
- [ ] Shared Runners aktiviert ODER Self-Hosted Runner registriert
- [ ] Erste Pipeline erfolgreich durchgelaufen
- [ ] Pipeline Badge im README hinzugefügt
- [ ] Protected Branches konfiguriert
- [ ] Merge Request Approvals aktiviert

**Wenn alle Punkte  sind: Herzlichen Glückwunsch! CI/CD ist einsatzbereit! 🎉**
