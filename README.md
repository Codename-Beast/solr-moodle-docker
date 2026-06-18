# Solr für Moodle — Multi-Tenant Docker Stack

[![CI](https://github.com/Codename-Beast/solr-moodle-docker/actions/workflows/solr-testing.yml/badge.svg?branch=release_1.0)](https://github.com/Codename-Beast/solr-moodle-docker/actions/workflows/solr-testing.yml)
![Version](https://img.shields.io/badge/version-3.4.9-blue)
![Solr](https://img.shields.io/badge/solr-9.10.1-orange)
![Moodle](https://img.shields.io/badge/moodle-4.1--5.x-purple)
![Tested](https://img.shields.io/badge/getestet-Debian%2012%2F13-green)

Docker-Stack für **Solr + Moodle Global Search** mit Multi-Tenant-Isolation.

- Standalone oder SolrCloud (embedded ZooKeeper)
- Tenant-User + Core/Collection-Isolation pro Moodle-Instanz
- Tika `/update/extract` für Datei-Indexierung (PDF, DOCX, HTML, …)
- Security-Bootstrap via globalen Init-Container `eLeDia-solr-init`
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

**Init-Prozess (globalisiert):**
`eLeDia-solr-init` schreibt/aktualisiert `security.json`, Default-Configsets und Bootstrap-Metadaten.
Der Runtime-Container startet erst nach erfolgreichem Init (`depends_on: service_completed_successfully`).

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

# Drift detection (runtime API/ZK vs tenants.env)
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh drift-detect

# Drift remediation (enforce SOT back to runtime)
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh drift-remediate

# Export runtime-aligned host_vars (includes solr_runtime_source_of_truth)
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh export
```

---

## SolrCloud (optional)

In `.env`:

```bash
SOLR_MODE=solrcloud
ZK_MAX_CNXNS=60
```

Hinweise:
- Die interne SolrCloud-Collection `.system` wird beim Start idempotent automatisch erzeugt, falls sie fehlt (Schema Designer benötigt sie).
- Schema Designer Upload-Guardrails: max. 5MB pro Sample; `text/markdown` wird nicht unterstützt.

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
| Aufwand | geringer | höher |
| Empfehlung | kleine/mittlere Installationen | größere Multi-Tenant-Setups / Wachstumspfad |

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

## Bare-Metal 8/9/10/11 -> Docker Upgrade (einseitig)

Wichtig: Dieser Pfad ist bewusst **nur Upgrade**, kein Downgrade/Back-Switch.

```bash
# Beispiel: Instanz "kunde1", alter systemd-Service "solr", Domain für Naming-Schema
sudo ./scripts/upgrade-docker.sh \
  --instance kunde1 \
  --legacy-service solr \
  --customer-domain kunde1.example.de
```

Was das Skript macht:
- exportiert vorhandene Bare-Metal-Cores (aus erkanntem/gesetztem SOLR_HOME)
- stoppt und deaktiviert die alte systemd-Solr-Instanz
- startet die Docker-Instanz idempotent (`INSTANCE_NAME`-basiert)
- importiert Core-Daten in `solr_data_<INSTANCE_NAME>`
- loggt mit Instanz-/Container-Kontext (`[instance:..][container:..]`)

Core-Namensschema:
- Standard: `core_<kundendomain>` (Domain wird zu lowercase + `_` normalisiert)
- Wenn keine Domain/keine exportierten Cores vorhanden: `eledia_moodle_core`

Mehrere Instanzen:
- vollständig über `--instance` unterstützt
- erkennbare Runtime-Namen bleiben konsistent:
  - Container: `<instance>-solr`, `<instance>-eLeDia-solr-init`
  - Volume: `solr_data_<instance>`
  - Network: `<instance>-network`

Optional systemd-Integration (oneshot template):

```bash
sudo cp systemd/upgrade-docker@.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start upgrade-docker@kunde1.service
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

## Konfiguration

Alle Optionen in `.env.example` dokumentiert. Wichtigste Variablen:

| Variable | Default | Beschreibung |
|----------|---------|--------------|
| `INSTANCE_NAME` | `solr` | Präfix für Container und Volumes |
| `SOLR_PORT` | `8983` | Solr-Port (nur auf 127.0.0.1 gebunden) |
| `SOLR_BIND` | `127.0.0.1` | **Nicht ändern** — Proxy übernimmt externe Zugriffe |
| `SOLR_HEAP` | `2g` | JVM Heap für Solr |
| `SOLR_MODE` | `solrcloud` | SolrCloud-Modus (Default) |
| `ELEDIA_LOG_ROOT` | `/var/log/eledia/solr` | Host-Root für init/setup/install/runtime Logs |
| `INIT_TARGETS` | `solr-a,solr-b,solr-c` | Zielmetadaten für globalisierten Init-Lauf |
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
├── Dockerfile                  # eLeDia-solr-init Bootstrap-Container
├── Dockerfile.solr             # Solr Runtime (mit Tika-Modul)
├── init/
│   ├── powerinit.sh            # Bootstrap: security.json + Tenant-Permissions
│   └── security.json.template  # Init-Template für Security JSON
├── eLeDia-config/
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

**eLeDia.de** · BSC Bernd Schreistetter
