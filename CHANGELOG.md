# Changelog

Format: Keep a Changelog
Versioning: Semantic Versioning

## [3.0.3] - 2026-05-24

### Fixed
- Markdown-Dokumente bereinigt (entfernte versehentliche Zeilenpraefix-Artefakte wie `123|`).
- Doku-Stand fuer CI/Status/Open-Issues konsolidiert (`docs/STATUS-2026-05-24.md`).
- Flaky CI in `scripts/test-moodle-documents.sh` behoben: Marker-Suche nach Tika-Indexierung nutzt jetzt robusten Fallback (`ELEDIA+TIKA+TEST+MARKER`), und ist nicht mehr build-blockierend wenn Analyzer `_`-Tokenisierung anders behandelt.

### Docs
- README + Docs auf aktuellen Betriebs- und Teststand aktualisiert.

---

## [3.0.2] - 2026-05-24

### Added
- Copyright/SPDX/Version Header in allen Shell-Skripten:
  - `Copyright (c) 2026 Eledia GmbH / Bernd Schreistetter`
  - `SPDX-License-Identifier: MIT`
  - `Version: v3.0.1`
- README komplett auf code-nahe Betriebsdoku umgestellt (TL;DR, SolrCloud, Tests, CI, Security, Ops).
- Dokumentierte Solr-Doku-Tweaks fuer `/update/extract`.

### Changed
- `docker-compose.yml`: dynamische Portbelegung bewusst beibehalten:
  - `${SOLR_BIND}:${SOLR_PORT}:${SOLR_PORT}`
  - Healthcheck URLs weiter mit `${SOLR_PORT}` (kein Hardcode auf 8983).
- `config/solrconfig.xml`: Tika Feld-Mapping verbessert:
  - `fmap.content=solr_filecontent`
  - Ergebnis: extrahierter Datei-Text landet gezielt im Moodle-Dateifeld.
- `.gitlab-ci.yml`: DinD robuster gemacht fuer klassische Docker-Runner:
  - `DOCKER_HOST=tcp://docker:2375`
  - `DOCKER_TLS_CERTDIR=""`
  - `DOCKER_DRIVER=overlay2`
  - `docker:24-dind` Service in Test-Template
  - Docker-Readiness-Wait (`until docker info ...`)

### Verified
- Lokale Testsuite erfolgreich gelaufen (port-isoliert):
  - `./scripts/run-tests.sh --unit-only`
  - `./scripts/run-tests.sh --integration-only --no-cleanup`
  - `./scripts/run-tests.sh --security-only --no-cleanup`
- Shell-Syntax-Pruefung ueber alle `.sh` im Repo: OK (`bash -n`).
- GitHub Actions Runs fuer beide Repos erneut angestossen / rerun gestartet.

---

## [3.0.1] - 2026-05-22

### Fixed
- `setup.sh` Re-Run-Idempotenz: bestehende `.env` wird nicht mehr ungefragt ueberschrieben.
- `tenants.env` Rechte/Owner fuer Solr UID 8983 verbessert.
- `powerinit.sh` fail-fast bei fehlenden/Placeholder-Passwoertern.
- SolrCloud Security-Bootstrap in ZooKeeper stabilisiert.
- SolrCloud ZK-Port aus `SOLR_PORT + 1000` ableitbar gemacht.

---

## [3.0.0] - 2026-05-10

### Added
- Multi-Tenant CLI (`scripts/solr-tenant.sh`) mit create/delete/list/passwd/apply/export/caddy-config.
- SolrCloud Modus (`SOLR_MODE=solrcloud`) inkl. Collections API Pfad.
- `tenants.env` als Source of Truth fuer Tenant-Konfiguration.
- CI-Abdeckung fuer Standalone + SolrCloud + Tika.

### Changed
- `init/powerinit.sh` generiert Tenant-Permissions dynamisch.
- `managed-schema` verschlankt (kein `_text_` copyField-Pattern mehr).
- Monitoring/Setup Altlasten aus Compose entfernt.

[3.0.2]: https://github.com/Codename-Beast/solr-moodle-docker/compare/v3.0.1...v3.0.2
[3.0.1]: https://github.com/Codename-Beast/solr-moodle-docker/compare/v3.0.0...v3.0.1
[3.0.0]: https://github.com/Codename-Beast/solr-moodle-docker/releases/tag/v3.0.0
