# Solr 8.x -> 10.0: Impact-Analyse für dieses Repository

Stand: 2026-05-27
Quelle: Apache Solr Upgrade Notes (`major-changes-in-solr-9`, `major-changes-in-solr-10`, `solr-upgrade-notes`)

## Kurzfazit

Für dieses Projekt sind die Änderungen **nicht grundsätzlich disruptiv**, wenn wir
- bei der Security API bleiben,
- tenantbezogene Checks auf API-Ebene halten,
- und den Moduswechsel (standalone/solrcloud) technisch reproduzierbar absichern.

Die größten Risiken liegen in Betriebsparametern (CLI/Jetty/Overseer/Routing), nicht in Moodles API-Verwendung selbst.

## Relevante Änderungen (komprimiert)

1. Solr 9 (Upgrade von 8.x)
- Ausbau/Anpassungen rund um SolrCloud- und Collections-Verhalten.
- Mehr Fokus auf API- und Cloud-zentrierte Betriebsmodelle.
- Deprecations/Removals in Randbereichen (CLI/Legacy-Patterns abhängig vom Einsatz).

2. Solr 10 (Upgrade von 9.x)
- Anpassungen bei Solr CLI/Skripten und Jetty-Parametern.
- Änderungen im SolrCloud-Overseer-/Routing-Umfeld.
- SolrJ- und Vektor/NLP-Themen erweitert (für dieses Repo sekundär).

## Bewertung für solr-moodle-docker

Direkt betroffen:
- Mode-spezifische Provisionierung (standalone core vs. cloud collection)
- Security- und Tenant-Autorisierung über API
- Restart-/Recovery-Timing bei Testläufen

Nicht primär betroffen:
- Moodle-Client-Protokoll (Moodle spricht weiterhin Solr-HTTP-API)
- Reverse-Proxy-Grundprinzip

## Umgesetzte Schutzmaßnahmen im Repo

- Port-Strategie bleibt dynamisch (`SOLR_PORT`) in Compose und Tests.
- HTTP-000 Root Cause behoben (fehlerhafte Port-Rewrite-Logik in Tests entfernt).
- SolrCloud-Restartpfade mit Readiness-Retry stabilisiert.
- Mode-Portability-Schnittstelle ergänzt:
  - `scripts/solr-mode-portability.sh export`
  - `scripts/solr-mode-portability.sh import`
  - `scripts/solr-mode-portability.sh switch --to ...`
- Moduswechsel-Test ergänzt:
  - `scripts/test-mode-switch.sh`
  - in Test-Suite via `./scripts/run-tests.sh --mode-switch`

## Lessons Learned (intern, professional)

1. Keine impliziten Port-Annahmen
- Tests dürfen dynamische Portbelegung nie auf feste interne Ports zurückbiegen.

2. Security/Isolation immer API-nah verifizieren
- Read/Write/Admin-Pfade getrennt prüfen, insbesondere nach Restart.

3. Idempotenz vor Striktheit
- Bei `already exists` nicht blind fehlschlagen; Zustand fachlich bewerten.

4. Recovery-Fenster einplanen
- Nach Restart immer Ready/Recovery-Puffer in Tests berücksichtigen.

5. Schema-Drift aktiv erkennen
- "stille" API-/Feldprobleme (z. B. ignorierte Felder) nur durch explizite Assertions sichtbar machen.

## Empfehlung für Upgrade-Prozess

1. Upgrade-Arbeit nur auf Feature-Branch (`feature/solr-<major>-<minor>-upgrade`).
2. Pflichtläufe vor MR:
   - `./scripts/run-tests.sh --unit-only --tenant --cloud`
   - `./scripts/run-tests.sh --mode-switch`
3. Vor Merge: Main als EOL-Archivbranch sichern (`main_eol_solr-<major>-<minor>_<YYYY-MM-DD>`).
4. Erst dann MR nach `main`.
5. Release-/Operations-Doku im gleichen MR aktualisieren.
