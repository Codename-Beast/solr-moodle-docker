# Solr für Moodle — Multi-Tenant Docker Stack

[![CI](https://github.com/Codename-Beast/solr-moodle-docker/actions/workflows/solr-testing.yml/badge.svg?branch=release_1.0)](https://github.com/Codename-Beast/solr-moodle-docker/actions/workflows/solr-testing.yml)
![Version](https://img.shields.io/badge/version-3.0.8-blue)
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

---

## Tests

```bash
# Unit-Tests (Dateien, Permissions, Config)
./scripts/run-tests.sh --unit-only

# Vollständige Testsuite (benötigt laufenden Stack)
./scripts/run-tests.sh

# Moodle-Dokument-Indexierung (Tika)
./scripts/test-moodle-documents.sh
```

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
