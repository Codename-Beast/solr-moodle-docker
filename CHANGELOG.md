# Changelog

All notable changes to this project will be documented in this file.

## [3.4.10] - 2026-06-22

### Fixed
- `powerinit.sh` und `_cloud_authz_api` validieren Solr-Permissions jetzt vor dem Schreiben bzw. API-Call und blockieren ungültige Permission-Namen wie `admin`. Root-cause: Solr lädt `admin` nur als Rolle, nicht als Permission-Name; ein solcher Eintrag führt beim RuleBasedAuthorizationPlugin zu `Permission with name admin is neither a pre-defined permission nor qualifies as a custom permission`.
- `_cloud_authz_api` lehnt zusätzlich ungültiges JSON und nicht-numerische `delete-permission`-Payloads ab, damit Solr Security API-Fehler nicht erst als eingebettete Runtime-Fehler sichtbar werden.
- `solr-tenant.sh passwd --password` erzwingt in SolrCloud nach der Credential-Rotation erneut Tenant-Rolle und Permission-Rebuild. Root-cause: Das Passwort wurde gesetzt, aber der Zugriff konnte danach mit HTTP 403 statt 200 enden, wenn der Live-Security-State die Tenant-Rolle/ACL nicht sauber nachgezogen hatte.
- `solr-tenant-api.sh` und `solr-backup.sh` lesen Admin-Credentials jetzt gezielt aus `.env`, statt die komplette Datei zu sourcen/exportieren. Root-cause: `set -a; . .env` konnte ungewollte Variablen wie `PATH` in Tenant-/Backup-Prozesse übernehmen.
- `_solr_api` schreibt Response- und Curl-Fehlerdateien jetzt in ein privates temporäres Verzeichnis und räumt es über `RETURN`-Trap sowie explizite Cleanup-Pfade auf. Root-cause: Direkte `/tmp/solr-api-*` Dateien waren unnötig breit sichtbar und konnten bei Abbruch liegen bleiben.
- `scripts/test-integration.sh` setzt `tenants.env` nicht mehr world-writable, sondern nutzt `chown 8983:8983` mit `chmod 660`.
- `scripts/test-moodle-documents.sh` sourcet `.env` nur noch einmal, damit Runtime-Konfig und Credentials nicht doppelt mit Seiteneffekten geladen werden.
- `init/powerinit.sh` loggt die Standalone-Core-Vorerzeugung nur noch im Standalone-Modus. Root-cause: SolrCloud-Starts meldeten vorher direkt nach dem Skip fälschlich trotzdem „Pre-creating core directories“.
- `solr-cloud-entrypoint.sh` nutzt jetzt `runuser` statt `gosu` für den Privilege-Drop, und `Dockerfile.solr` entfernt die zusätzliche `gosu`-Abhängigkeit.
- `solr-tenant.sh` bricht auf Bash-Versionen vor 4 jetzt früh mit einer klaren Fehlermeldung ab, statt später bei assoziativen Arrays unsauber zu scheitern.
- `solr-cloud-entrypoint.sh` bricht jetzt hart ab, wenn `solr-tenant.sh apply` oder `sync-sot` beim Start fehlschlägt. Root-cause: Der Entrypoint hat vorher nur gewarnt und mit halb initialisiertem Tenant-/Security-State weitergestartet.
- Security-Reload-Waits schlagen jetzt fehl, statt bei Timeout stillschweigend weiterzulaufen. Root-cause: `_wait_for_security_reload` meldete Erfolg, obwohl Solr den neuen Auth-State nie übernommen hatte.
- SolrCloud-Tenant-Flows warten nicht mehr auf einen lokalen Security-Reload, weil der Auth-State in ZooKeeper persistiert wird. Root-cause: Der vorherige Wait-Check hat ZK-persistierte Änderungen als fehlenden Reload fehlinterpretiert und `create`/`enable`/`passwd`/`core-add` abgebrochen.
- Tenant-Passwort- und Enable-Flows schreiben `PASS` / `ACTIVE` jetzt vor dem Reload-Wait weg und brechen sauber ab, wenn der Reload nicht kommt. Root-cause: Das Script konnte weiterlaufen, obwohl `tenants.env` und der Live-Solr-Auth-State nicht mehr synchron waren.
- Core-Namen werden jetzt konsistent validiert, bevor sie in Solr oder die Tenant-Konfiguration geschrieben werden. Root-cause: Die erste Validator-Version war für bestehende branded Namen wie `eLeDia_core_a` zu streng, dadurch wurden gültige Tenants vor dem Start abgelehnt.
- `cmd_apply` stoppt jetzt bei einem fehlschlagenden Core-Create, statt den Fehler zu schlucken und den Tenant als erfolgreich angewendet zu markieren. Root-cause: Die Schleife ignorierte `_create_core`-Fehler, dadurch blieb `apply` fälschlich auf Erfolg.
- Der Compose-Healthcheck nutzt jetzt den tenant-aware `solr-tenant.sh healthcheck` statt nur Solr-Liveness zu prüfen und behandelt SolrCloud-Drift nicht mehr als Startup-Fehler, sondern nur Bootstrap/Auth-Status. Root-cause: Der alte Check konnte grün melden, obwohl Tenant-Drift oder defekte ACLs noch vorhanden waren, und drift-gesicherte Runtime-Zustände wurden sonst fälschlich als Fehler markiert.

### Added
- Neue Unit-Abdeckung prüft den Hard-Fail-Startup-Pfad, die Core-Name-Validierung und das Timeout-Verhalten beim Security-Reload.
- Die Unit-Tests validieren Security-Template-Permissions gegen Solr-vordefinierte Namen und Custom-Permission-Regeln, damit eine ungültige Permission wie `admin` nicht wieder in `security.json` landet.
- Die Testmatrix berücksichtigt den bootstrap-sicheren Healthcheck jetzt explizit, damit frische Volumes nicht mehr als Drift-Fehler behandelt werden.
- Reverse-Proxy- und Architektur-Diagramme wurden in der Doku ergänzt.

### Changed
- Der Test-Log-Fallback nutzt jetzt ein UID-spezifisches Verzeichnis unter `/tmp`, damit alte nicht beschreibbare Fallback-Logs lokale Testläufe nicht blockieren.

### Removed
- Keine.

### Deprecated
- Keine.

### Breaking Changes
- Keine.

## [3.4.9]

### Fixed
- `solr-tenant.sh rebuild-permissions` ist jetzt ein eigener Befehl und baut SolrCloud-Tenant-ACLs aus `tenants.env` neu auf, wobei die Fallback-Permission `all` zuletzt bleibt.
- `solr-tenant.sh passwd` akzeptiert jetzt `--password <pass>`, damit die Orchestrierung hostvars-gelieferte Tenant-Passwörter direkt über das Container-Skript durchsetzen kann, ohne inline Security-API-Schreiblogik.
- Die neu aufgebauten SolrCloud-Collection-ACLs werden vor den breiten eingebauten `read`-/`update`-Berechtigungen eingefügt, damit tenant-spezifische Schreibregeln vor generischen First-Match-Regeln greifen.
- Die Unit-Abdeckung prüft jetzt, dass der öffentliche Dispatcher den Tenant-Permission-Rebuild-Befehl für Orchestrierungsschichten sichtbar macht.
- `scripts/run-tests.sh --tenant` führt jetzt die Tenant-Command-Matrix aus, und diese Matrix prüft `passwd --password` mit Ablehnung des alten Passworts und erfolgreichem Login mit explizitem Passwort.
- Die Smart-Rebuild-Checksummen von `upgrade-docker.sh` umfassen jetzt alle Runtime-Shellskripte im Solr-Image sowie beide Security-Templates.
- Der Init-Container bindet `tenants.env` jetzt read-only ein, und die Unit-Tests stellen sicher, dass beide Security-Templates identisch bleiben.

### Removed
- Keine.

### Deprecated
- Keine.

### Breaking Changes
- Keine.

## [3.4.8]

### Fixed
- `scripts/generate-test-tenants.sh` meldet jetzt die echte Tenant-Anzahl statt die Header-Zeilen fälschlich als zusätzlichen Tenant mitzuzählen.
- Der SolrCloud-Tenant-ACL-Rebuild gruppiert jetzt alle aktiven Tenant-Rollen pro Collection, damit mehrere Tenants absichtlich dieselbe Collection teilen können, ohne dass First-Match die ACLs verschluckt.
- Das Aufräumen von Solr-Autorisierungsberechtigungen löscht jetzt per numerischem Security-API-Index und behält genau eine Fallback-Permission `all` am Ende.
- `apply`, `create`, `enable` und `core-add` bauen SolrCloud-Collection-Permissions jetzt vor der Endpunktprüfung aus `tenants.env` neu auf.
- Drift-Detection und SOT-Sync behandeln inaktive Tenant-User und erhaltene Tenant-Collections aus `tenants.env` jetzt als verwalteten Laufzeit-Zustand und ignorieren die interne `.system`-Collection von Solr.

### Removed
- Keine.

### Deprecated
- Keine.

### Breaking Changes
- Keine.

## [3.4.7]

### Fixed
- `scripts/run-tests.sh` delegiert Logging, Env-Setup und Counter-Setup jetzt vollständig an `scripts/test-lib.sh`; doppeltes Tee-Logging und doppelter Bootstrap-State sind damit weg.
- Der Sicherheits-Test für `/admin/system` in Moodle respektiert jetzt `${SOLR_PORT}` statt fest `8983` zu verwenden.
- Die CI führt Timing-/Last-/Performance-Assertions auf Shared Runnern nicht mehr aus; lokale Performance-Tests bleiben verfügbar und fallen bei gesetztem `CI` nur noch als Warnung durch.
- SolrCloud-Tests prüfen jetzt das Verhalten von `drift-detect`/`drift-remediate` und verifizieren, dass die Fallback-Permission `all` die letzte Autorisierungsregel ist.
- Das Parsing der Moodle-Dokument-Testresultate nutzt jetzt eine maschinenlesbare Summary-Zeile im Format `RESULTS:total=...;passed=...;failed=...`.
- Trivy bleibt bei neuen CRITICAL-Funden weiterhin fail-closed, während akzeptierte CVEs aus den gebündelten Solr-Java-Dependencies in `.trivyignore` dokumentiert sind.
- Die GitLab-Docker-in-Docker-CI toleriert jetzt Runner-Host-Bind-Mount-Einschränkungen über einen image-eigenen Configset-Fallback und einen container-lokalen Tenant-SOT-Pfad.
- CI für Passwortrotation und Moodle-Log-Health prüft Runtime-Verhalten jetzt direkt und ignoriert bekannte Solr-ZooKeeper-ACL-Bootstrap-Warnungen.
- Das Init-Bootstrap nutzt bei GitLab-Docker-Socket-Runnern ohne File-Bind-Mounts ebenfalls image-eigene Config-Fallbacks und den konfigurierten Tenant-SOT-Pfad.
- Test-Summaries ergänzen jetzt fehlende rohe `[FAIL]`-Zeilen aus dem Run-Log, damit ein sichtbarer Fehler nicht mehr aus der Fehlerliste verschwinden kann.
- Der Admin-`.env`-Passwort-Rotationstest läuft jetzt nur noch außerhalb von SolrCloud; SolrCloud hält aktive Security in ZooKeeper und wird stattdessen über Drift-/Remediation-Tests abgedeckt.
- Moodle-Readiness funktioniert jetzt für Tenant-User sowohl in `SOLR_MODE=solrcloud` als auch in `SOLR_MODE=standalone`; die tenant-spezifischen Read-ACLs enthalten den Moodle-Read-Pfad und lassen breite Admin-Fallback-Regeln zuletzt stehen.
- Die Standalone/Core-Runtime bildet den Privilege-Drop-Pfad von SolrCloud jetzt nach: Der Entrypoint korrigiert Volume-Ownership als root und re-execed als `solr`, bevor `solr-foreground` startet, damit `SOLR_MODE=standalone` zuverlässig startet statt an Solrs Root-Guard zu scheitern.
- Die Zähler des Test-Harness werden jetzt ausschließlich von `run-tests.sh`/`test-lib.sh` initialisiert und über importierte Testmodule hinweg beibehalten, sodass frühe `[FAIL]`-Ergebnisse nicht mehr von späteren Modul-Resets verdeckt werden.
- `scripts/solr-tenant-cmd.sh`: Die Drift-Detection liest `tenants.env` jetzt einmal vor der Iteration und vermeidet damit Pipeline-Hazards beim Lesen/Schreiben derselben Datei sowie ShellCheck-Funde SC2094/SC2143.
- `scripts/test-moodle-documents.sh`: Der SolrCloud-Precheck erzeugt jetzt keinen Core mehr über die Core-Admin-API. Er erkennt den Modus und legt bzw. prüft im SolrCloud-Modus eine Collection über die Collections-API an; Standalone bleibt Core-Logik vorbehalten.
- `scripts/test-moodle-documents.sh`: Die Solr-Log-Basis wird nach Setup-Aktionen (Core/Collection-Absicherung) neu berechnet, damit Startup-/Setup-Fehlerzeilen die abschließende Log-Healthprüfung nicht mehr verschmutzen.

### Changed
- Die Unit-/Static-Testausführung benötigt jetzt keine lokale `.env` mehr, sodass frische Checkouts und Entwickler-Sanity-Checks vor dem Generieren von Runtime-Secrets laufen können.

### Removed
- Keine.

### Deprecated
- Keine.

### Breaking Changes
- Keine.


## [3.4.0]

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

### Fixed
  `/var/log/solr/` to `/var/log/eledia/*/` to match new host log layout.


## [3.3.1]

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
- Configset renamed: `moodle-tenant` → `eLeDia-moodle-tenant` (ZooKeeper, Collections API, all references).
- Core/collection names: `moodle_core` → `eLeDia_core`, `moodle_cloud_*` → `eLeDia_cloud_*`.
- Config directory: `config/` → `eLeDia-config/` (host-side schema and solrconfig).
- SolrCloud bootstrap: automatic `security.json` + configset upload to ZooKeeper + collection creation on first start.
- `.github/workflows/solr-testing.yml` — push triggers, mode-switch job, containerized linting.

## [3.0.8]

### Changed
- `config/solrconfig.xml`: `/update/extract` mappt `fmap.content` jetzt auf `content` (kanonisches Suchfeld).
- `config/managed-schema`: `copyField content -> solr_filecontent` ergänzt (Rückwärtskompatibilität für bestehende Abfragen/Tools).
- `scripts/test-moodle-documents.sh`: PDF-Marker-Prüfung jetzt strikt und deterministisch (`q=content:...` + `fq=id:tika_test_pdf`).
- README bewusst vereinfacht und für Onboarding klarer gemacht.

## [3.0.7]

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

## [3.0.6] 

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

---

## Branch-Sync-Check

- Nicht uebernommene CHANGELOG-Commits aus anderen Branches geprueft.
- Offene Branch-Eintraege fuer moeglichen Rueckmerge:
- `feature/v2.3.0`: 8bbc9dc
- `feature/v2.5.0`: 85d9821
Versioning: Semantic Versioning

## [3.0.5]

### Changed
- GitHub Actions (`.github/workflows/solr-testing.yml`): `paths-ignore` fuer Docs-only Commits hinzugefuegt.
- CI-Topologie optimiert: `solrcloud-test` haengt jetzt direkt an `security-scan` (parallel zu `solr-test`).
- `Dockerfile.solr`: Base-Image auf Digest gepinnt (`solr:9.10.1@sha256:...`).
- Operatives Snapshot-Dokument `REPORT.md` aus dem Repository entfernt.

---

## [3.0.4]

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

---

## [3.0.3]

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
- CI-Testablauf angepasst, damit Analyzer-Details nicht mehr zu False-Negatives im Build fuehren.
- `docs/architecture.md` in beiden Repos um ASCII-Architekturdiagramme erweitert.
- Compose-/Runtime-Warnungen reduziert:
- Named-Volume SELinux-Flag (`:z`) an `solr_data` entfernt (Docker warning beseitigt).
- `maxBooleanClauses` auf global konsistente 1024 gesetzt (Core-Load WARN beseitigt).
- Security-Manager/JVM-Noise reduziert (`SOLR_SECURITY_MANAGER_ENABLED=false`, `-XX:-UseLargePages`).

---

## [3.0.2]

### Added
- Dokumentierte Solr-Doku-Tweaks für `/update/extract`.

### Changed
- Healthcheck URLs weiter mit `${SOLR_PORT}`.
- `config/solrconfig.xml`: Tika Feld-Mapping verbessert:
- `fmap.content=solr_filecontent`
- Ergebnis: extrahierter Datei-Text landet gezielt im Moodle-Dateifeld.
- `DOCKER_HOST=tcp://docker:2375`
- `DOCKER_TLS_CERTDIR=""`
- `DOCKER_DRIVER=overlay2`
- Docker-Readiness-Wait (`until docker info ...`)
---

## [3.0.1]

### Fixed
- `setup.sh` Re-Run-Idempotenz: bestehende `.env` wird nicht mehr ungefragt ueberschrieben.
- `tenants.env` Rechte/Owner fuer Solr UID 8983 verbessert.
- `powerinit.sh` fail-fast bei fehlenden/Placeholder-Passwoertern.
- SolrCloud Security-Bootstrap in ZooKeeper stabilisiert.
- SolrCloud ZK-Port aus `SOLR_PORT + 1000` ableitbar gemacht.

---

## [3.0.0]

### Added
- Multi-Tenant CLI (`scripts/solr-tenant.sh`) mit create/delete/list/passwd/apply/export/caddy-config.
- SolrCloud Modus (`SOLR_MODE=solrcloud`) inkl. Collections API Pfad.
- `tenants.env` als Source of Truth fuer Tenant-Konfiguration.
- CI-Abdeckung fuer Standalone + SolrCloud + Tika.

### Changed
- `init/powerinit.sh` generiert Tenant-Permissions dynamisch.
- `managed-schema` verschlankt (kein `_text_` copyField-Pattern mehr).
- Monitoring/Setup Altlasten aus Compose entfernt.

