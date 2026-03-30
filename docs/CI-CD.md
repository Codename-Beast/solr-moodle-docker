# CI/CD Pipeline

Tests laufen bei jedem Push — GitHub Actions und GitLab CI.

---

## GitLab CI/CD

### Quick Start

```bash
# .gitlab-ci.yml liegt schon im Repo
git push gitlab develop
```

### Was getestet wird

- Syntax & Struktur
- Container-Build
- Unit Tests (Dateistruktur, Permissions)
- Integration Tests (Startup, Health-Checks)
- Security Tests (Auth, Permissions)
- Moodle Document Tests (Indexierung, Queries)
- Custom Core-Namen (Matrix-Tests)

### Setup

- [GitLab Quick Start (5 Min)](GITLAB-QUICKSTART.md) — fuer GitLab.com
- [Vollstaendige Anleitung](GITLAB-CI-CD-SETUP.md) — fuer Self-Hosted

### Pipeline Badge

```markdown
[![Pipeline](https://gitlab.com/USER/solr-moodle-docker/badges/main/pipeline.svg)](https://gitlab.com/USER/solr-moodle-docker/-/pipelines)
```

---

## GitHub Actions

Workflow: [.github/workflows/solr-testing.yml](../.github/workflows/solr-testing.yml)

Laeuft automatisch bei Push/PR auf `main` oder `develop`.

Ablauf: Environment Setup → `.env` generieren → Init-Container bauen → Solr starten → Health-Check → Unit/Integration/Security/Moodle Tests → Cleanup.

---

## Konfiguration

### GitLab CI/CD

Pipeline in `.gitlab-ci.yml`. Braucht:
- Docker-faehige Runner (Tag: `docker`)
- Mindestens 4 GB RAM

### GitHub Actions

`ubuntu-latest` mit Docker. Keine Extra-Konfiguration.

### Matrix-Tests

Beide Systeme testen parallel mit verschiedenen Core-Namen:
- `moodle_core` (Standard)
- `custom_test_core` (Custom-Core-Feature)

---

## Lokale Tests

```bash
# Setup
docker compose --profile setup up moodle_setup
docker compose up -d

# Einzeln
./scripts/run-tests.sh --unit-only
./scripts/run-tests.sh --integration-only
./scripts/run-tests.sh --security-only
./scripts/test-moodle-documents.sh

# Alles
./scripts/run-tests.sh

# Aufraeumen
docker compose down -v
rm -f .env
```

### Mit custom Core-Namen

```bash
SOLR_CORE_NAME=test_core docker compose --profile setup up moodle_setup
docker compose up -d
./scripts/run-tests.sh
docker compose down -v
rm -f .env
```

---

## Troubleshooting

**"Generate .env" schlaegt fehl:** `moodle_setup` Service in `docker-compose.yml` pruefen.

**Tests erreichen Solr nicht:** Healthcheck-Config pruefen, Solr braucht etwas bis es antwortet.

**Permission Denied:**
```bash
chmod +x scripts/run-tests.sh scripts/test-moodle-documents.sh
```

---

## Support

Pipeline-Logs anschauen, lokal testen, Issue auf GitHub/GitLab erstellen.
