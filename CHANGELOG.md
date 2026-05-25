# Changelog

All notable changes to this project will be documented in this file.

## [3.0.8] - 2026-05-25

### Changed
- `config/solrconfig.xml`: `/update/extract` mappt `fmap.content` jetzt auf `content` (kanonisches Suchfeld).
- `config/managed-schema`: `copyField content -> solr_filecontent` ergänzt (Rückwärtskompatibilität für bestehende Abfragen/Tools).
- `scripts/test-moodle-documents.sh`: PDF-Marker-Prüfung jetzt strikt und deterministisch (`q=content:...` + `fq=id:tika_test_pdf`).
- README bewusst vereinfacht und für Betrieb/Onboarding klarer gemacht.
- Alle Markdown-Dokumente auf Release-1.0-Hinweis und aktuellen Stand gebracht.

### Verified
- Lokaler Lauf: `./scripts/test-moodle-documents.sh` erfolgreich (48/48).
- GitHub Actions Run `26415360780` erfolgreich (Code Quality, Security Scan, Solr Tests, SolrCloud Tests).

### Branch-Merge Übersicht (release_1.0)
- Für `release_1.0` wurden CHANGELOG-Linien aus allen verfügbaren Remote-Branches geprüft:
  - `main`, `develop`, `develop22`
  - `feature/multi-tenant`, `feature/v2.3.0`, `feature/v2.3.2`, `feature/v2.3.3`, `feature/v2.4.0`, `feature/v2.5.0`
  - `fix/solrcloud-security-ci`, `fix/powerinit-security-prometheus`, `fix/security-permissions-order`, `fix/test-robustness-v2.3`, `fix/test-robustness-v2.3.1`
  - `feature/docs-and-ci-hardening-2026-05-24`
- Relevante Versionslinien sind jetzt im Release-Changelog enthalten: `2.0.0` bis `3.0.8`.
- Historische Branch-Sync-Hinweise bleiben im Verlauf erhalten, damit nichts still verloren geht.

## [3.0.7] - 2026-05-25

### Added
- Neue Shell-Fixture-Generierung (`tests/create-moodle-fixtures.sh`) fuer Moodle/Solr Tika-Tests ohne Python-Abhaengigkeit.
- Multi-Format-Testabdeckung in `scripts/test-moodle-documents.sh` erweitert:
- TXT, HTML, CSV, RTF, PNG (Photo-Fixture) zusaetzlich zur PDF-Pruefung.
- Fuer jedes Format: `/update/extract`-Indexing + ID-Verifikation.
- Fuer textbasierte Formate: `extractOnly`-Pruefung auf erwartete Marker.
- Persistente Log-Dokumentation: `tests/solr-log-findings.md` wird pro Testlauf erzeugt (WARN/ERROR/SEVERE-Befunde).

### Changed
- Test-Hinweise/Erzeugung auf Shell umgestellt (`sh tests/create-moodle-fixtures.sh`).
- Fehlende `print_skip`-Hilfsfunktion in `scripts/test-moodle-documents.sh` ergänzt.
- Lange Moodle-Kompatibilitaetsabfragen auf `POST /select` umgestellt (group visibility + combined filters), um Jetty-`URI is too large >8192` Warnungen zu vermeiden.
- Solr-Log-Healthcheck praezisiert:
- bekannte, nicht-funktionale Startup-/PDFBox-Font-WARNs werden als non-actionable gefiltert.
- neue harte Pruefung auf `URI is too large` bleibt separat aktiv.

### Verified
- `./scripts/test-moodle-documents.sh` -> PASS (47/47).
- `./scripts/run-tests.sh --moodle-only` -> PASS (47/47).
- Solr Log Healthcheck: keine actionable WARN/ERROR/SEVERE und keine URI-Overflow-WARN im Testlauf.

## [3.0.6] - 2026-05-25

### Changed
- `scripts/test-moodle-documents.sh` fachlich verfeinert, damit die Query-Checks Moodle-Solr-Engine-Logik realistisch abbilden (Moodle 4.1 bis 5.2 Zielbild):
- hinzugefuegt: `{!cache=false}`-Filter-Patterns fuer `courseid` und `areaid`.
- hinzugefuegt: Owner-Visibility-Filter (`owneruserid:(-1 OR <userid>)`) inkl. korrektem Escaping fuer negative IDs (`\-1`).
- hinzugefuegt: Context-Filter (`contextid:(...)`) und Moodle-typisches Group/Context-Fallback-Pattern.
- hinzugefuegt: kombinierte Mehrfach-Filter-Query (q + mehrere fq), wie sie Moodle beim Eingrenzen nutzt.
- Query-Assertions in Hilfsfunktion `assert_min_hits()` konsolidiert, damit Checks reproduzierbar und wartbar bleiben.

### Added
- Neuer Abschnitt `SOLR LOG HEALTHCHECK` in `scripts/test-moodle-documents.sh`:
- prueft nach dem Query-/Indexing-Workload die letzten Solr-Logs auf actionable `ERROR/SEVERE`.
- prueft actionable `WARN` separat.
- gibt bei Befunden die ersten Logzeilen sichtbar aus, statt still zu scheitern.

### Fixed
- False-Positive im neuen Logcheck entfernt:
- Root cause: naive Suche auf `ERROR` matchte auch harmlose Info-Zeilen wie `solr.log.level=ERROR`.
- Fix: Regex auf echtes Solr-Loglevel-Format verschaerft (`... ERROR|SEVERE (`).
- Owner-Filter-Query korrigiert:
- Root cause: `-1` ohne Escaping fuehrte zu falscher Query-Interpretation.
- Fix: URL-encodiertes `\-1` (`%5C-1`) fuer stabile Trefferlogik.

### Verified
- `./scripts/test-moodle-documents.sh` -> PASS (32/32)
- `./scripts/run-tests.sh --moodle-only` -> PASS (32/32)
- Solr Log Healthcheck im Testlauf: keine actionable WARN/ERROR gefunden.

---

## Branch-Sync-Check (2026-05-24)

- Nicht uebernommene CHANGELOG-Commits aus anderen Branches geprueft.
- Offene Branch-Eintraege fuer moeglichen Rueckmerge:
- `feature/v2.3.0`: 8bbc9dc
- `feature/v2.5.0`: 85d9821
Versioning: Semantic Versioning

## [3.0.5] - 2026-05-24

### Changed
- GitHub Actions (`.github/workflows/solr-testing.yml`): `paths-ignore` fuer Docs-only Commits hinzugefuegt.
- CI-Topologie optimiert: `solrcloud-test` haengt jetzt direkt an `security-scan` (parallel zu `solr-test`).
- `Dockerfile.solr`: Base-Image auf Digest gepinnt (`solr:9.10.1@sha256:...`).
- Operatives Snapshot-Dokument `REPORT.md` aus dem Repository entfernt.
- README um Kompatibilitaetsmatrix zur ansible-role-solr ergaenzt.

### Verified
- `./scripts/run-tests.sh --unit-only` erfolgreich.
- `./scripts/run-tests.sh --integration-only --no-cleanup` erfolgreich.
- `./scripts/test-moodle-documents.sh` erfolgreich.

---

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
