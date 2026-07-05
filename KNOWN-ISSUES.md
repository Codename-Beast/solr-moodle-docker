# Known Issues — Bug-Hunt Review

Stand: 2026-07-05
Geprüfte Stände:
- solr-moodle-docker: v3.4.10 (Review) → Fixes in Branch `feature/3.4.11`
- ansible-role-solr: v1.9.15 (Review) → Fixes in Branch `feature/1.9.16`

Methode: statische Analyse (shellcheck, yamllint, ansible-lint production-profile),
Code-Review der kritischen Pfade (Backup, Healthcheck, Tenant-Parsing, Entrypoint,
Proxy-Generatoren), lokale Unit-Suite, CI-Läufe auf GitHub geprüft.

---

## Behoben in feature/3.4.11 (Stack)

### Backup nutzte im SolrCloud-Betrieb die falsche API — BEHOBEN

`solr-backup.sh` sicherte ausschließlich über die Core-Level Replication API,
obwohl der Stack seit v3.4.0 SolrCloud-Default fährt. Ein Replication-Snapshot
einer einzelnen Replica enthält keinen Collection-State und ist nicht als
Collection wiederherstellbar.
Fix: Das Skript unterscheidet jetzt nach `SOLR_MODE` — SolrCloud sichert über
die Collections API (`action=BACKUP`), Standalone weiter über Replication.
Zusätzlich exportiert Compose `BACKUP_DIR` in den Container und erlaubt denselben
Pfad über `solr.allowPaths` (`SOLR_BACKUP_ALLOW_PATHS`), damit Collections API
BACKUP/RESTORE mit expliziter `location` nicht an Solrs Pfad-Whitelist scheitert.

### Backup meldete Erfolg bei nur "initiiertem" Backup — BEHOBEN

Die Replication API arbeitet asynchron: HTTP 200 heißt "angestoßen", nicht
"fertig". Das Skript wertete HTTP 200 als Erfolg und prüfte nie den
Snapshot-Status.
Fix: Standalone-Backups pollen `command=details` bis zum Erfolg und schlagen
nach `BACKUP_WAIT_TIMEOUT` (Default 120s) fehl. Teilfehler führen zu
Exit-Code ungleich null.

### Kein Restore-Pfad im Stack — BEHOBEN (Verifikation offen)

Der Stack hatte kein Restore-Skript; nur die Ansible-Rolle rendert ein
eigenes Template auf den Host.
Fix: Neues `scripts/solr-restore.sh` für beide Modi (Replication
`command=restore` + `restorestatus`-Polling / Collections API `action=RESTORE`),
mit `--list`, `--force` und automatischer Auswahl des neuesten Backups.
OFFEN: Ein echter End-to-End-Restore-Test gegen einen laufenden Stack mit
indexierten Dokumenten steht weiterhin aus.

### Healthcheck meldete hängenden Security-Bootstrap als "healthy" — BEHOBEN

`cmd_healthcheck` gab bei fehlender Auth immer "Bootstrap needed" mit
Exit 0 zurück — ohne Abgleich mit dem Bootstrap-Marker. Ein dauerhaft
festhängender Security-Bootstrap hielt den Container für immer "healthy",
während Solr unauthentifiziert antwortete.
Fix: Ist der Bootstrap-Marker vorhanden, aber Auth nicht aktiv, meldet der
Healthcheck jetzt unhealthy. Die legitime Erststart-Phase bleibt unberührt.

### `eval "$@"` im Upgrade-Skript — BEHOBEN

Der Dry-Run-Wrapper in `upgrade-docker.sh` führte Kommandos per `eval` aus
(Word-Splitting-/Injection-Risiko bei Pfaden mit Sonderzeichen).
Fix: Kommandos laufen jetzt als Argv-Arrays (`"$@"`), stdout-Unterdrückung
über separaten `run_quiet`-Wrapper.

### Doppelte Backups bei geteilten Collections — BEHOBEN

Die Backup-Schleife iterierte pro Tenant über dessen Core-Liste; geteilte
Collections wurden mehrfach pro Lauf gesichert.
Fix: Cores werden vor dem Backup dedupliziert (`sort -u`).

### Tenant-Passwörter in der Host-Prozessliste — BEHOBEN

`passwd --password <klartext>` via `docker exec` macht das Passwort in
`/proc/<pid>/cmdline` auf dem Host sichtbar; `no_log` schützt nur das
Ansible-Log.
Fix (Stack): Neues `passwd --password-stdin` liest das Passwort von stdin.
Fix (Rolle, feature/1.9.16): `tasks/tenants.yml` übergibt das Passwort per
Environment-Variable + stdin an `--password-stdin`.

Alle Fixes sind durch Unit-Tests abgedeckt (Pattern- und Verhaltenstests,
u.a. Backup-Verhaltenstest mit gemocktem curl und RED-Case für den
hängenden Bootstrap). Lokale Suite: 44/44 PASS.

---

## Behoben in feature/1.9.16 (Ansible-Rolle)

### Fehlgeschlagenes Tenant-Löschen wird stillschweigend verschluckt — BEHOBEN

`tasks/tenants.yml`: Der `delete --force`-Task hatte `failed_when: false` ohne
Auswertung von rc/stderr. Ein Tenant mit `state: absent`, dessen Löschung
fehlschlug, blieb aktiv — der Play endete grün.
Fix: Der Play bricht bei Löschfehlern jetzt ab; nur der "not found"-Fall
(bereits abwesend = Zielzustand) wird toleriert.

### Versions-Header-Drift — BEHOBEN

`tasks/tenants.yml` trug im Header "Version: v1.9.5" bei Rollenversion 1.9.15.
Fix: Header korrigiert; neues Regression-Playbook
`tests/tenant_task_hardening_test.yml` prüft Header-Konsistenz,
stdin-Passwortübergabe und das delete-Fehlerverhalten und läuft in der
CI-Lint-Stage mit.

## Offen — Ansible-Rolle

### Toter Monitoring-Code

`tasks/monitoring_stack.yml`: 307 Zeilen deprecated Code, eingebunden mit
`when: false` + `tags: [never]`.
Status: Entfernung zurückgestellt (User-Entscheidung steht aus).

### Stack-Pin auf Feature-Branch

`defaults/main.yml` pinnt `solr_repo_version` auf einen Feature-Branch
(jetzt `feature/3.4.11` mit den Backup-/Restore-Fixes).
Kontext: Das Arbeits-GitLab führt nur `master`, dort entschärft. Für das
GitHub-Referenz-Repo bleibt es Drift-Risiko.
Empfehlung: Nach Merge Tag setzen und Pin auf das Tag drehen.

---

## Offen — Prozess

### Kein voller CI-Lauf auf dem 3.4.10-Release-HEAD

Der letzte voll grüne GitHub-Lauf auf feature/3.4.10 lag 8 Commits vor HEAD
(SolrCloud-Job des Proxy-Commits wurde durch cancel-in-progress abgebrochen,
Folge-Commits waren Docs ohne CI-Trigger). Zusätzlich divergierten main und
feature/3.4.10 in den CI-Definitionen.
Empfehlung: Auf dem gemergten Master-Stand (Arbeits-GitLab) einmal die volle
Pipeline laufen lassen. Für feature/3.4.11 wurde der Push mit CI-Trigger
abgesetzt — Ergebnis prüfen.

---

## Bewusst NICHT aufgenommen (geprüft, kein Bug)

- Tenant-Namens-Parsing in `_load_tenants` (powerinit.sh): Namen mit
  Unterstrichen werden korrekt zerlegt, Feld-Suffixe sind eindeutig.
- `((VAR++)) || true` unter `set -e`: korrekt abgesichert.
- Configset-Fallback-Kette im Cloud-Entrypoint: alle Stufen enden in hartem
  Fehler mit klarer Meldung — gewollt und sauber.
- 30-Tenant-Limit im CI-Skalentest: bewusste Entscheidung (Laufzeit ~15 min
  bei 30 Tenants in GitHub Actions).
- `solr-tenant-cmd.sh` über der internen 800-Zeilen-Konvention: kein Bug,
  Refactoring-Kandidat.
