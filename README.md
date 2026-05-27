# Solr für Moodle — Multi-Tenant Docker Stack

[![CI](https://github.com/Codename-Beast/solr-moodle-docker/actions/workflows/solr-testing.yml/badge.svg?branch=release_1.0)](https://github.com/Codename-Beast/solr-moodle-docker/actions/workflows/solr-testing.yml)
![Version](https://img.shields.io/badge/version-3.1.0-blue)
![Solr](https://img.shields.io/badge/solr-9.10.1-orange)
![Moodle](https://img.shields.io/badge/moodle-4.1--5.x-purple)
![Tested](https://img.shields.io/badge/getestet-Debian%2012%2F13-green)

Docker-Stack für **Solr + Moodle Global Search** mit Multi-Tenant-Isolation.

- Standalone oder SolrCloud (embedded ZooKeeper)
- Tenant-User + Core/Collection-Isolation pro Moodle-Instanz
- Tika `/update/extract` für Datei-Indexierung (PDF, DOCX, HTML, …)
- Security-Bootstrap via `solr-init` One-Shot Container
- CI für Standalone und SolrCloud auf GitHub + GitLab

---

## Architektur

```
Moodle ──HTTPS──► Reverse Proxy (Apache/Caddy/Nginx)
                         │
                   127.0.0.1:${SOLR_PORT}
                         │
                    ┌────▼────┐
                    │  Solr   │◄── /update/extract (Tika)
                    │ 9.10.1  │
                    └────┬────┘
                         │
              ┌──────────┼──────────┐
         solr_data   Host-Logs   Backups
       (Index+Security)
```

**Init-Prozess (einmalig):**
`solr-init` schreibt `security.json` → Solr startet erst nach erfolgreichem Init.

**Runtime:**
Moodle → Proxy → `127.0.0.1:${SOLR_PORT}` → Tenant-Core/Collection

---

## Schnellstart

```bash
git clone https://github.com/Codename-Beast/solr-moodle-docker
cd solr-moodle-docker
cp .env.example .env
# Pflichtpasswörter setzen — kein CHANGE_ME drin lassen
$EDITOR .env
docker compose up -d --build
```

Health-Check:

```bash
docker compose ps
curl -u "admin:<SOLR_ADMIN_PASSWORD>" \
  "http://127.0.0.1:${SOLR_PORT:-8983}/solr/admin/info/system"
```

---

## Tenant-Verwaltung

```bash
# Tenant anlegen
docker exec solr-solr \
  /opt/solr/scripts/solr-tenant.sh create schule_a --cores moodle_prod

# Liste aller Tenants
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh list

# Passwort rotieren
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh passwd schule_a

# Source-of-Truth Sync (.env + tenants.env → Solr API)
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh sync-sot
```

---

## SolrCloud (optional)

In `.env`:

```bash
SOLR_MODE=solrcloud
```

Neu starten:

```bash
docker compose up -d --build
```

Moodle konfiguriert Collections statt Cores — alles andere bleibt identisch.

## Modusvergleich: Standalone vs. SolrCloud

Beide Modi funktionieren mit derselben Moodle-API (`/solr/<core|collection>/...`).
Die Unterschiede liegen im Betrieb, nicht in der Moodle-Anbindung.

| Kriterium | Standalone | SolrCloud |
|-----------|------------|-----------|
| Setup-Komplexität | niedriger | höher |
| Tenant-Isolation | über Security + Proxy-Regeln | nativ über Collections + Security API |
| Skalierung | vertikal / einzelner Node | horizontal erweiterbar |
| Betriebsaufwand | geringer | höher |
| Empfehlung | kleine/mittlere Installationen | größere Multi-Tenant-Setups / Wachstumspfad |

Praxisregel:
- Wenn ein einzelner Node reicht und Betrieb simpel bleiben soll: **Standalone**.
- Wenn Collection-basierte Isolation und spätere Skalierung zentral sind: **SolrCloud**.

Wichtig: `SOLR_PORT` bleibt in beiden Modi dynamisch, damit mehrere Instanzen parallel möglich sind.

---

## Tests

```bash
# Unit-Tests (Dateien, Permissions, Config)
./scripts/run-tests.sh --unit-only

# Vollständige Testsuite (benötigt laufenden Stack)
./scripts/run-tests.sh

# Moodle-Dokument-Indexierung (Tika)
./scripts/test-moodle-documents.sh

# Optional: Moduswechsel-Test (standalone <-> solrcloud)
./scripts/run-tests.sh --mode-switch
```

Zusätzlich für kontrollierte Migrationen:

```bash
# Tenant/Core-Mapping exportieren
./scripts/solr-mode-portability.sh export --out /tmp/solr-portability.json

# Manifest importieren
./scripts/solr-mode-portability.sh import --in /tmp/solr-portability.json

# Modus umschalten inkl. Export/Import-Replay
./scripts/solr-mode-portability.sh switch --to solrcloud
./scripts/solr-mode-portability.sh switch --to standalone
```

---

## Release-, Upgrade- und EOL-Branch-Strategie

Damit Upgrades reproduzierbar bleiben und alte Hauptstände nachvollziehbar archiviert sind,
verwenden wir folgende Branch-Namen:

- Feature/Upgrade-Branch:
  - `feature/solr-<major>-<minor>-upgrade` (z. B. `feature/solr-10-0-upgrade`)
- EOL-Archiv-Branch für den bisherigen Main-Stand:
  - `main_eol_solr-<major>-<minor>_<YYYY-MM-DD>`
  - Beispiel: `main_eol_solr-9-10_2026-05-27`

Warum ein EOL-Archiv-Branch?

- Der alte `main` repräsentiert eine produktiv genutzte Solr-Generation, die mit dem Upgrade
  bewusst verlassen wird.
- Für Audits, Rollback-Szenarien und Kunden-/Betriebsnachweise muss dieser Zustand
  unverändert und eindeutig benannt erhalten bleiben.
- `main_eol_*` macht auf einen Blick sichtbar:
  - welche Solr-Linie beendet wurde,
  - wann der Stand eingefroren wurde,
  - dass auf diesem Branch keine Feature-Weiterentwicklung mehr stattfindet
    (nur Notfall-/Dokufixes nach expliziter Freigabe).

Empfohlener Upgrade-Ablauf:

1. Upgrade-Arbeit auf `feature/solr-<major>-<minor>-upgrade`.
2. CI muss auf dem Feature-Branch vollständig grün sein.
3. Vor Merge: aktuellen `main` als `main_eol_*` branch/taggen und pushen.
4. Merge Request von Feature -> `main` erstellen.
5. Nach Merge: Release Notes/CHANGELOG finalisieren.

---

## Konfiguration

Alle Optionen in `.env.example` dokumentiert. Wichtigste Variablen:

| Variable | Default | Beschreibung |
|----------|---------|--------------|
| `INSTANCE_NAME` | `solr` | Präfix für Container und Volumes |
| `SOLR_PORT` | `8983` | Solr-Port (nur auf 127.0.0.1 gebunden) |
| `SOLR_BIND` | `127.0.0.1` | **Nicht ändern** — Proxy übernimmt externe Zugriffe |
| `SOLR_HEAP` | `2g` | JVM Heap für Solr |
| `SOLR_MODE` | `` | `solrcloud` für ZooKeeper-Modus |
| `SOLR_ADMIN_PASSWORD` | — | Pflicht — kein CHANGE_ME |
| `SOLR_SUPPORT_PASSWORD` | — | Pflicht — kein CHANGE_ME |

---

## Sicherheitshinweise

- `SOLR_BIND=127.0.0.1` — Solr nie direkt exponieren
- `tenants.env` enthält Secrets — bleibt unversioniert (in `.gitignore`)
- Passwörter mit CHANGE_ME werden beim Start abgewiesen
- Jeder Tenant bekommt eigenen Solr-User mit minimalen Rechten

---

## Verzeichnisstruktur

```
solr-moodle-docker/
├── docker-compose.yml          # Stack-Definition
├── .env.example                # Konfigurationsvorlage
├── Dockerfile                  # solr-init Bootstrap-Container
├── Dockerfile.solr             # Solr Runtime (mit Tika-Modul)
├── init/
│   ├── powerinit.sh            # Bootstrap: security.json + Tenant-Permissions
│   └── security.json.template  # Solr Security-Template
├── config/
│   ├── managed-schema          # Moodle-Felder + solr_filecontent (Tika)
│   └── solrconfig.xml          # /update/extract Handler
├── scripts/
│   ├── solr-tenant.sh          # Tenant-CLI (create/list/passwd/sync-sot)
│   ├── run-tests.sh            # Testsuite (unit/integration/security)
│   └── test-moodle-documents.sh # Tika-Dokument-Tests
├── .github/workflows/          # GitHub Actions CI
├── .gitlab-ci.yml              # GitLab CI
└── docs/                       # Betriebsdokumentation
```

---

## Dokumentation

| Dokument | Inhalt |
|----------|--------|
| [docs/architecture.md](docs/architecture.md) | Architektur, Komponenten, Tenant-Lifecycle |
| [docs/CI-CD.md](docs/CI-CD.md) | CI/CD Pipeline — GitHub + GitLab |
| [docs/GITLAB-CI-CD-SETUP.md](docs/GITLAB-CI-CD-SETUP.md) | GitLab Runner Setup |
| [docs/GITLAB-QUICKSTART.md](docs/GITLAB-QUICKSTART.md) | GitLab Schnellstart (5 Minuten) |
| [docs/monitoring.md](docs/monitoring.md) | Prometheus + Loki Integration |
| [CHANGELOG.md](CHANGELOG.md) | Vollständige Änderungshistorie |

---

## Kompatibilität

| Komponente | Version |
|------------|---------|
| Solr | 9.10.1 |
| Moodle | 4.1 – 5.x |
| Docker | 24+ |
| OS | Debian 11/12, Ubuntu 22.04/24.04 |

---

**Eledia GmbH** · BSC Bernd Schreistetter · [MIT License](LICENSE)
