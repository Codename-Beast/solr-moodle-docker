# Changelog

Format: Keep a Changelog
Versioning: Semantic Versioning

## [3.0.4] - 2026-05-24

### Fixed
- CI-Regression in `Run Moodle document tests` behoben (GitHub Actions Run 26352731461):
  - Root Cause: `/update/extract` wurde mit `literalsOverride=false` konfiguriert; dadurch konnten `literal.*`-Metadaten fuer Moodle-Pflichtfelder beim Tika-Indexing nicht verlaesslich greifen.
  - Symptom: `PDF indexing via Tika failed (HTTP 400)` in CI, obwohl `extractOnly=true` HTTP 200 lieferte.
  - Fix: `config/solrconfig.xml` setzt fuer `/update/extract` wieder `literalsOverride=true`.
- `scripts/run-tests.sh`: False-Green beseitigt.
  - Vorher konnte bei `Failed > 0` trotzdem `TEST SUITE PASSED` erscheinen (nur success-rate-basiert).
  - Jetzt: jeder fehlgeschlagene Test erzwingt Exit-Code != 0 und `TEST SUITE FAILED`.
- Tenant-Lifecycle-Test idempotent gemacht.
  - Test-Tenant-Name ist pro Run eindeutig (`ci_lifecycle_<timestamp>_<random>`), damit keine Kollision mit Altzustand auftritt.
- Hardening bleibt erhalten:
  - `captureAttr=false` bleibt aktiv.
  - Upload-Limits via System-Properties bleiben aktiv (`solr.multipartUploadLimitKB`, `solr.formdataUploadLimitKB`).

### Verified
- Lokal reproduziert und verifiziert:
  - `./scripts/test-moodle-documents.sh` -> PASS inkl. Tika PDF Indexing
  - `./scripts/run-tests.sh --integration-only --no-cleanup` -> PASS

---

## [3.0.3] - 2026-05-24

### Fixed
- Markdown-Dokumente bereinigt (entfernte versehentliche Zeilenpraefix-Artefakte wie `123|`).
- CI-YAML-Lintfehler beseitigt (`docker-compose.yml` Zeilenlaenge in `SOLR_OPTS` auf block-scalar umgestellt).
- `scripts/test-moodle-documents.sh` robust gemacht fuer lokale/non-CI Runs:
  - Port-/Core-Defaults werden nach `.env`-Load korrekt aufgeloest.
  - fehlender Test-Core wird automatisch via Core Admin API erstellt.
  - Connectivity-Check nutzt jetzt `select?q=*:*&rows=0` statt `admin/ping`.
- `scripts/run-tests.sh` ist jetzt CI-robust bei Log-Pfaden:
  - Fallback von `/var/log/eledia` auf `/tmp/eledia-logs`, falls Runner keine Schreibrechte auf `/var/log` hat.
  - verhindert fruehen Abbruch in Unit-Stage bei ansonsten lauffaehigem Stack.
- Tika-/PDF-Assertion in `scripts/test-moodle-documents.sh` stabilisiert:
  - Root Cause: `text_general` nutzt `StandardTokenizerFactory`; Marker mit `_` werden tokenisiert.
  - Konsequenz: exakte Query `ELEDIA_TIKA_TEST_MARKER` ist schema-/analyzer-abhaengig und kann 0 Treffer liefern, obwohl Inhalt indexiert ist.
  - Fix: Fallback-Query (`ELEDIA+TIKA+TEST+MARKER`) und semantischer Folgecheck bleiben verpflichtend.

### Added
- Tenant-Management-Lifecycle in `scripts/run-tests.sh` erweitert:
  - `create` (mehrere Cores)
  - `core-remove`
  - `core-add`
  - `delete` (deactivate)
  - `enable` (reactivate)
  - jeweils mit Zustandsverifikation via `solr-tenant.sh info`.

### Changed
- Statusdokumentation konsolidiert (`docs/STATUS-2026-05-24.md`).
- CI-Testablauf angepasst, damit Analyzer-Details nicht mehr zu False-Negatives im Build fuehren.
- `docs/architecture.md` in beiden Repos um code-nahe ASCII-Architekturdiagramme erweitert.
- Compose-/Runtime-Warnungen reduziert:
  - Named-Volume SELinux-Flag (`:z`) an `solr_data` entfernt (Docker warning beseitigt).
  - `maxBooleanClauses` auf global konsistente 1024 gesetzt (Core-Load WARN beseitigt).
  - Security-Manager/JVM-Noise reduziert (`SOLR_SECURITY_MANAGER_ENABLED=false`, `-XX:-UseLargePages`).

### Docs
- README + Betriebsdoku auf aktuellen Stand gebracht; tenantbezogene Testabdeckung und Fehlerstatus nachgezogen.

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

[3.0.4]: https://github.com/Codename-Beast/solr-moodle-docker/compare/v3.0.3...v3.0.4
[3.0.3]: https://github.com/Codename-Beast/solr-moodle-docker/compare/v3.0.2...v3.0.3
[3.0.2]: https://github.com/Codename-Beast/solr-moodle-docker/compare/v3.0.1...v3.0.2
[3.0.1]: https://github.com/Codename-Beast/solr-moodle-docker/compare/v3.0.0...v3.0.1
[3.0.0]: https://github.com/Codename-Beast/solr-moodle-docker/releases/tag/v3.0.0
