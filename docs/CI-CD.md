# CI/CD Pipeline

Automatisierte Tests für Solr-Moodle-Docker bei jedem Push.

---

## GitLab CI/CD

### Quick Start

```bash
# .gitlab-ci.yml ist bereits konfiguriert
# Pushe einfach zu GitLab:
git push gitlab develop
```

### Was wird getestet?

- Syntax & Struktur-Validierung
- Container-Build
- Unit Tests (Dateistruktur, Permissions)
- Integration Tests (Container-Startup, Health-Checks)
- Security Tests (Authentifizierung, Permissions)
- Moodle Document Tests (Indexierung, Queries)
- Custom Core-Namen Feature (Matrix-Tests mit verschiedenen Core-Namen)

### Setup-Anleitungen

- [GitLab Quick Start (5 Min)](GITLAB-QUICKSTART.md) - Für GitLab.com
- [Vollständige Anleitung](GITLAB-CI-CD-SETUP.md) - Für Self-Hosted GitLab

### Pipeline Badge

```markdown
[![Pipeline](https://gitlab.com/USER/solr-moodle-docker/badges/main/pipeline.svg)](https://gitlab.com/USER/solr-moodle-docker/-/pipelines)
```

---

## GitHub Actions (Alternative)

Falls du GitHub verwendest, ist bereits eine Workflow-Datei vorhanden:
[.github/workflows/solr-testing.yml](../.github/workflows/solr-testing.yml)

### Tests werden automatisch ausgeführt bei:

- Push auf `main` oder `develop` Branches
- Pull Requests auf `main` oder `develop`

### Workflow-Schritte

1. Environment Setup (Ubuntu + Docker)
2. Generate `.env` file
3. Build init container
4. Start Solr containers
5. Wait for health check
6. Run unit tests
7. Run integration tests
8. Run security tests
9. Run Moodle document tests
10. Cleanup

---

## Konfiguration

### GitLab CI/CD

Die Pipeline ist definiert in `.gitlab-ci.yml` und benötigt:
- Docker-fähige Runner
- Runner-Tag: `docker`
- Mindestens 4 GB RAM

### GitHub Actions

Verwendet `ubuntu-latest` Runner mit vorinstalliertem Docker.
Keine zusätzliche Konfiguration erforderlich.

### Matrix-Tests

Beide CI-Systeme (GitLab und GitHub Actions) führen Tests parallel mit verschiedenen Core-Namen aus:
- `moodle_core` (Standard)
- `custom_test_core` (Test für custom Core-Namen Feature)

Dies stellt sicher, dass das optionale SOLR_CORE_NAME Parameter beim Setup korrekt funktioniert.

---

## Lokale Tests

Du kannst die Tests auch lokal ausführen:

```bash
# Setup mit Standard Core-Namen
docker compose --profile setup up moodle_setup
docker compose up -d

# Unit Tests
./scripts/run-tests.sh --unit-only

# Integration Tests
./scripts/run-tests.sh --integration-only

# Security Tests
./scripts/run-tests.sh --security-only

# Moodle Document Tests
./scripts/test-moodle-documents.sh

# Alle Tests
./scripts/run-tests.sh

# Cleanup
docker compose down -v
rm -f .env
```

### Lokale Tests mit custom Core-Namen

```bash
# Setup mit custom Core-Namen
SOLR_CORE_NAME=test_core docker compose --profile setup up moodle_setup
docker compose up -d

# Tests ausführen
./scripts/run-tests.sh

# Cleanup
docker compose down -v
rm -f .env
```

---

## Troubleshooting

### Pipeline schlägt fehl bei "Generate .env"

Stelle sicher, dass das `moodle_setup` Service korrekt definiert ist in `docker-compose.yml`.

### Tests können Solr nicht erreichen

Überprüfe die Healthcheck-Konfiguration und stelle sicher, dass Solr vollständig gestartet ist.

### Permission Denied Fehler

Stelle sicher, dass die Test-Scripts ausführbar sind:
```bash
chmod +x scripts/run-tests.sh scripts/test-moodle-documents.sh
```

---

## Support

Bei Problemen mit der CI/CD Pipeline:
1. Überprüfe die Pipeline-Logs
2. Teste lokal mit den Skripten
3. Erstelle ein Issue auf GitHub/GitLab
