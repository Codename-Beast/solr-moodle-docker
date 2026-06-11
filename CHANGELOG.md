# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [3.4.7] - 2026-06-12

### Fixed
- GitLab CI branch rules now match numbered feature branches such as `feature/3.4.6` as well as legacy `feature/v*` names.
- Removed the dead GitHub Actions CI tenant pre-step and centralized tenant creation in the runtime test harness.
- `scripts/run-tests.sh` now delegates all logging/env/counter setup to `scripts/test-lib.sh`, eliminating duplicate tee logging and duplicated bootstrap state.
- Moodle `/admin/system` security test now honors `${SOLR_PORT}` instead of hardcoding `8983`.
- CI no longer runs timing/load performance assertions on shared runners; local performance tests remain available and degrade to warnings when `CI` is set.
- SolrCloud tests now assert drift-detect/drift-remediate behavior and verify that fallback permission `all` is the last authorization rule.
- Moodle document test result parsing now uses a machine-readable `RESULTS:total=...;passed=...;failed=...` summary line.
- Moodle readiness now works for tenant users in both `SOLR_MODE=solrcloud` and `SOLR_MODE=standalone`; tenant read ACLs include Moodle's Solr system-read path while keeping broad admin-only fallback permissions last.
- Standalone/Core runtime now mirrors the SolrCloud privilege-drop path: the entrypoint fixes volume ownership as root and re-execs as the `solr` user before starting `solr-foreground`, so `SOLR_MODE=standalone` starts reliably instead of failing Solr's root-user guard.
- Test harness counters are now initialized only by `run-tests.sh`/`test-lib.sh` and are preserved across sourced test modules, so earlier `[FAIL]` results can no longer be masked by later module-level counter resets.

- GitHub Actions SolrCloud test steps now fail closed when test output contains `[FAIL]`, even if a future harness regression would otherwise return a green exit status.

- `scripts/solr-tenant-cmd.sh`: drift detection reads `tenants.env` once before iterating, avoiding same-file read/write pipeline hazards and ShellCheck SC2094/SC2143 findings.
- `scripts/test-moodle-documents.sh`: SolrCloud precheck no longer creates a Core via Core Admin API. It now detects mode and creates/checks a Collection via Collections API in SolrCloud mode, keeping standalone Core logic only for standalone mode.
- `scripts/test-moodle-documents.sh`: Solr log baseline is recalculated after setup actions (core/collection ensure) so startup/setup error lines do not pollute the final actionable log healthcheck.

### Changed
- GitLab/GitHub CI documentation now matches the current pipelines and no longer documents the removed mode-switch CI job or obsolete unit-only GitLab lane.
- Unit/static test execution no longer requires a local `.env`, allowing fresh-checkout CI and developer sanity checks to run before runtime secrets are generated.

## [3.4.6] - 2026-05-30

### Changed
- Restored and promoted the one-shot init service as `eLeDia-solr-init` as default runtime architecture, including updated docs/diagrams for init responsibilities, multi-instance targeting, and host log flow.
- Standardized defaults around `eLeDia-config/` and `eLeDia-moodle-tenant` so schema/solrconfig are always bootstrapped from the eLeDia configset path.
- Clarified and aligned host log handling toward `/var/log/eledia/solr` style layouts (setup/runtime/install logs via host-mounted log roots).
- SolrCloud test suite now uses unique per-run cloud tenant/collection names to avoid stale-state collisions and make restart-persistence checks deterministic.

### Fixed
- `solr-tenant-api.sh`: replaced static `/tmp/_solr_resp` and `/tmp/_solr_err` files with `mktemp`-based request-local files to eliminate cross-run permission collisions that caused intermittent `HTTP <no response>` in tenant API operations.
- SolrCloud integration tests no longer depend on potentially inactive legacy `cloud_tenant` entries in `tenants.env`; this fixes false 401/collection-missing/persistence regressions in long-lived local test environments.
- Multi-tenant verification in integration tests now checks Solr Security API credentials (runtime source of truth) instead of relying on local `security.json` file inspection.
- `solr-tenant.sh export` now emits `solr_runtime_source_of_truth` metadata for host_vars so runtime authority (Solr API + ZooKeeper) is explicitly represented in exported inventory data.
- Added `solr-tenant.sh drift-detect` to detect runtime drift between tenants.env (desired) and runtime Solr API/ZooKeeper state (users/collections).
- Added `solr-tenant.sh drift-remediate` to reconcile detected drift by reapplying runtime state from source-of-truth (`sync-sot`).
- Enforced Solr permission ordering so fallback rule `all` is always moved to the end after apply/sync operations; this prevents broad-rule shadowing of tenant-specific ACLs.
- SolrCloud runtime now auto-creates internal `.system` collection (idempotent) to prevent Schema Designer `Collection not found: .system` errors.
- Added optional `ZK_MAX_CNXNS` runtime tuning and startup guardrail logging for Schema Designer sample constraints (5MB limit, no markdown).

### Verified
- Local run: `./scripts/run-tests.sh --integration-only --tenant --cloud --no-cleanup` → `8/8 PASS`.

## [3.4.0] - 2026-05-27

### Changed
- Removed one-shot init container (`solr-init` / `Dockerfile` / `powerinit.sh`) — SolrCloud
  bootstrap is fully handled by `solr-cloud-entrypoint.sh` on every container start.
  No more dead init container leaking per instance after first deploy.
- `docker-compose.yml`: `solr-init` service and `depends_on` removed; `SOLR_MODE` default
  changed to `solrcloud`; log volume updated to `ELEDIA_LOG_ROOT`.
- `SOLR_MODE` default changed to `solrcloud` in `docker-compose.yml` (SolrCloud is the
  only supported mode since Solr 10.1).
- Host log path changed from `/var/log/solr/instances/<name>/` to `/var/log/eledia/<name>/`
  — all Docker container logs of every instance land there for Promtail / syslog scraping.
  Controlled via `ELEDIA_LOG_ROOT` env var (default `/var/log/eledia`).
- Architecture diagram (`docs/architecture-runtime.svg`) updated: standalone mode removed,
  ZooKeeper / Collections layout and new log path documented.

### Added
- `ansible-role-solr` — `tasks/config.yml`: new `solr_config` task for rolling out updated
  Solr configs (managed-schema, solrconfig.xml) without container restart:
  - Detects changed files via checksum (`solr_config_new_dir` on control node)
  - Stages files to deploy dir, `docker cp` into container's `eLeDia-config/`
  - Re-uploads configset to ZooKeeper via `solr zk upconfig`
  - Reloads all (or a specific) collection via Collections API
  - Trigger: `--tags solr_config` or `solr_config_enabled: true`
- `ansible-role-solr` — `defaults/main.yml`: `solr_config_enabled`, `solr_config_new_dir`,
  `solr_config_collection`, `solr_config_zk_configset` defaults.
- `ansible-role-solr` — `defaults/main.yml`: `solr_eledia_log_root: /var/log/eledia`.
- `ansible-role-solr` — `templates/env.j2`: `ELEDIA_LOG_ROOT` written to `.env`.

### Fixed
- `ansible-role-solr` — `defaults/main.yml`: `solr_mode` default corrected to `solrcloud`.
- `ansible-role-solr` — `defaults/main.yml`: `solr_repo_version` updated to `feature/3.4.0`.
- `ansible-role-solr` — `tasks/setup.yml`: log dir and logrotate target changed from
  `/var/log/solr/` to `/var/log/eledia/*/` to match new host log layout.
- `ansible-role-solr` — `tasks/setup.yml`: logrotate config renamed to `eledia-solr`.

## [3.3.1] - 2026-05-27

### Refactored
- Monolithic scripts split into focused modules, all under 800 lines.
  - `solr-tenant.sh` (42 lines) — dispatcher; sources `solr-tenant-api.sh`, `solr-tenant-core.sh`, `solr-tenant-security.sh`, `solr-tenant-cmd.sh`
  - `run-tests.sh` (198 lines) — test orchestrator; sources `test-lib.sh`, `test-unit.sh`, `test-integration.sh`, `test-security.sh`, `test-moodle.sh`
- Removed stale dispatch block from `solr-tenant-cmd.sh` (caused `Unknown command: <tenant_name>` on every `source()`).
- Removed `docs/SOLR-8-to-10-impact.md` and `docs/STATUS-2026-05-24.md` (consolidated into README/CHANGELOG).
- Architecture diagrams replaced: stale `.d2` prototypes removed, clean SVG diagrams added (`docs/architecture-install.svg`, `docs/architecture-runtime.svg`).

### Fixed
- `cmd_core_add` — skips if core already assigned; prevents duplicate entries in `tenants.env`.
- `import_manifest` — `enable`/`delete` only triggered when tenant active state actually changes.
- `_create_core` — handles `coreNodeName missing` gracefully and verifies existence instead of relying on HTTP 200.
- `powerinit.sh` — `_default` configset always refreshed from `eLeDia-moodle-tenant` source on restart.
- `powerinit.sh` — `SOLR_MODE` no longer overwritten by `load_env()`.
- `powerinit.sh` — `tenant-read`/`tenant-write` permissions inserted before `all`.
- `setup.sh` — `tenants.env` permissions set to `644` so container solr user (uid 8983) can read the file.
- `docker-compose.yml` / `docker-compose.cloud-test.yml` — removed unnecessary SELinux `:z` flag from `tenants.env` mount.
- `scripts/solr-tenant-core.sh` — SolrCloud configset fallback to legacy `moodle-tenant/conf` path when `eLeDia-moodle-tenant` is missing.
- `scripts/solr-cloud-entrypoint.sh` — same configset path fallback for mixed legacy/new layouts.
- `scripts/run-tests.sh` — HTTP-000 root cause fixed (port resolution via `${SOLR_PORT}`, not `docker compose port`).
- `docker-compose.yml` — dynamic Solr port strategy restored (`${SOLR_BIND}:${SOLR_PORT}:${SOLR_PORT}`).
- `scripts/run-tests.sh` — SolrCloud restart tests hardened with `wait_for_solr_ready` + retry.
- `scripts/run-tests.sh` — tenant/collection create idempotent ("already exists" treated as valid state).
- GitLab `feature-full-test` — stack started explicitly before tests; fixes HTTP-000 on cold runner.

### Performance
- `upgrade-docker.sh` — conditional `--build`: skips image rebuild when Dockerfile/config/scripts unchanged (sha256 comparison).

### Changed
- eLeDia branding: all module headers standardized (`eLeDia GmbH / Bernd Schreistetter (bsc)`).
- Configset renamed: `moodle-tenant` → `eLeDia-moodle-tenant` (ZooKeeper, Collections API, all references).
- Core/collection names: `moodle_core` → `eLeDia_core`, `moodle_cloud_*` → `eLeDia_cloud_*`.
- Config directory: `config/` → `eLeDia-config/` (host-side schema and solrconfig).
- SolrCloud bootstrap: automatic `security.json` + configset upload to ZooKeeper + collection creation on first start.
- `docker-compose.cloud-test.yml` added for isolated SolrCloud integration testing.
- `scripts/solr-mode-portability.sh` — import/export/switch interface for standalone ↔ SolrCloud migration.
- `scripts/test-mode-switch.sh` — continuity test for `standalone → solrcloud → standalone`.
- `scripts/upgrade-docker.sh` — one-way bare-metal Solr 8/9/10/11 → Docker upgrade script.
- `systemd/upgrade-docker@.service` — systemd oneshot template for instance-based upgrades.
- `Dockerfile.wizard` — containerized wizard runner (debian:12-slim, whiptail + textual).
- `.github/workflows/solr-testing.yml` — push triggers, mode-switch job, containerized linting.
- Moodle plugin extracted to dedicated repo: `github.com/Codename-Beast/local_eledia_solrplus` (v0.0.1).

### Verified
- SolrCloud: 8 collections, 37 credentials, security active (401 anonymous), configset in ZK.
- Local run: `./scripts/run-tests.sh --unit-only --tenant --cloud` → 46/46 PASS.
- Mode-switch: `./scripts/test-mode-switch.sh` → PASS (`solrcloud → standalone` API continuity).

## [3.1.0] - 2026-05-26

### Changed
- `.gitlab-ci.yml` auf Runner-Realität ausgerichtet: konfigurierbarer Runner-Tag über `CI_RUNNER_TAG` klar dokumentiert und als Default im Pipeline-File hinterlegt.
- YAML-Header (`---`) ergänzt für konsistente Lint-Auswertung.

### Verified
- Lokaler CI-äquivalenter Lint-Check erfolgreich:
  - `docker compose --env-file .env.example config`
  - `bash -n` über alle versionierten `*.sh`

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
- Statusdokumentation konsolidiert.
- CI-Testablauf angepasst, damit Analyzer-Details nicht mehr zu False-Negatives im Build fuehren.
- `docs/architecture.md` in beiden Repos um ASCII-Architekturdiagramme erweitert.
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
- README auf Betriebsdoku umgestellt (TL;DR, SolrCloud, Tests, CI, Security, Ops).
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

---

## v1 Era (v2.0 – v2.5) — 2024-12 to 2026-04

The v2.x generation was the first stable Docker release of solr-moodle-docker.
It ran as a **single-tenant setup** (one Moodle per Solr core) with optional
Prometheus/Grafana monitoring and BasicAuth security.

Full details: [docs/HISTORY-v1.md](docs/HISTORY-v1.md)

| Version | Date       | Theme                                                  |
|---------|------------|--------------------------------------------------------|
| 2.0.0   | 2024-12-27 | Initial Docker release — Solr 9.10.0, single-tenant   |
| 2.1.0   | 2026-01-14 | GitLab CI, dynamic core name, `.env` location refactor |
| 2.1.1   | 2026-01-15 | Dockerfile simplified via `powerinit.sh` (273→30 lines)|
| 2.2.0   | 2026-01-15 | Security hardening, Trivy scanning, resource limits    |
| 2.2.1   | 2026-01-18 | CVE-2025-26519 musl hotfix (untagged)                  |
| 2.2.2   | 2026-01-24 | Apache reverse proxy templates, CI lint stage (untagged)|
| 2.3.0   | 2026-03-27 | Moodle 4.x `config-read` 403 fix, password entropy     |
| 2.3.1   | 2026-03-28 | Solr 9.10.1 CVE update                                 |
| 2.3.2   | 2026-03-30 | Security permission cleanup, monitoring removed        |
| 2.4.0   | 2026-04-18 | CI trigger cleanup                                     |
| 2.5.0   | 2026-04-18 | Log volume documentation                               |

[2.5.0]: https://github.com/Codename-Beast/solr-moodle-docker/compare/v2.4.0...v2.5.0
[2.4.0]: https://github.com/Codename-Beast/solr-moodle-docker/compare/v2.3.2...v2.4.0
[2.3.2]: https://github.com/Codename-Beast/solr-moodle-docker/compare/v2.3.1...v2.3.2
[2.3.1]: https://github.com/Codename-Beast/solr-moodle-docker/compare/v2.3.0...v2.3.1
[2.3.0]: https://github.com/Codename-Beast/solr-moodle-docker/compare/v2.2.0...v2.3.0
[2.2.0]: https://github.com/Codename-Beast/solr-moodle-docker/compare/v2.1.1...v2.2.0
[2.1.1]: https://github.com/Codename-Beast/solr-moodle-docker/compare/v2.1.0...v2.1.1
[2.1.0]: https://github.com/Codename-Beast/solr-moodle-docker/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/Codename-Beast/solr-moodle-docker/releases/tag/v2.0.0
