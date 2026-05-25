# Solr für Moodle — Multi-Tenant

[![CI](https://github.com/Codename-Beast/solr-moodle-docker/actions/workflows/solr-testing.yml/badge.svg?branch=release_1.0)](https://github.com/Codename-Beast/solr-moodle-docker/actions/workflows/solr-testing.yml)
![Version](https://img.shields.io/badge/version-3.0.8-blue)
![Solr](https://img.shields.io/badge/solr-9.10.1-orange)
![Moodle](https://img.shields.io/badge/moodle-4.1--5.x-purple)
![Tested](https://img.shields.io/badge/getestet-Debian%2012%2F13-green)

Docker-Stack für Solr + Moodle Global Search mit Multi-Tenant-Isolation.

- Standalone oder optional SolrCloud
- Tenant-User + Core/Collection-Isolation
- Tika `/update/extract` für Datei-Indexierung
- CI für Standalone und SolrCloud

---
Siehe [CHANGELOG.md](CHANGELOG.md) für alle Changes aus allen Branch-Linien.

## Architektur: Installation + Runtime

```mermaid
flowchart LR
  classDef panel fill:#0b0b0b,stroke:#f97316,color:#fdba74,stroke-width:2px
  classDef step fill:#141414,stroke:#ff8a00,color:#fed7aa,stroke-width:2px
  classDef cfg fill:#111111,stroke:#ea580c,color:#fb923c,stroke-width:2px
  classDef store fill:#0e0e0e,stroke:#c2410c,color:#fb923c,stroke-width:2px
  classDef opt fill:#171717,stroke:#78716c,color:#a8a29e,stroke-width:1.5px,stroke-dasharray:5 4

  M["Moodle / Workplace"]:::step

  subgraph I["Installation"]
    direction TB
    I1[".env + tenants.env
docker-compose.yml"]:::cfg
    I2["solr-init
one-shot bootstrap"]:::step
    I3["managed-schema + solrconfig.xml"]:::cfg
    I4["solr startet :8983
(nur nach init success)"]:::step
    I1 --> I2 --> I4
    I3 --> I4
  end
  class I panel

  subgraph R["Runtime"]
    direction TB
    R1["Reverse Proxy + TLS
Apache/Caddy/nginx"]:::step
    R2["Solr :8983
search/update/extract"]:::step
    R3["solr-tenant.sh
create/list/passwd/sync-sot"]:::cfg
    R1 --> R2
    R3 --> R2
  end
  class R panel

  subgraph P["Persistenz"]
    direction TB
    P1[("solr_data
index+cores+security.json")]:::store
    P2[("Host Logs
${ELEDIA_LOG_ROOT:-/var/log/eledia}")]:::store
    P3[("solr_backups")]:::store
  end
  class P panel

  subgraph O["Optional"]
    direction TB
    O1["SOLR_MODE=solrcloud"]:::opt
    O2["Exporter / Prometheus / Grafana"]:::opt
  end
  class O panel

  M -->|HTTPS /solr| R1
  I4 --> R2
  R2 --> P1
  R2 --> P2
  R2 --> P3
  O1 -.-> R2
  O2 -.-> R2
```

Installationsprozess (kurz):
1. `.env` und `tenants.env` pflegen.
2. `docker compose up -d --build` startet zuerst `solr-init`.
3. `solr-init` legt Security/Bootstrap ab; danach startet Solr.
4. Schema/Config (`managed-schema`, `solrconfig.xml`) ist aktiv.

Runtime-Prozess (klar getrennt):
- Moodle geht ausschließlich per HTTPS über Reverse Proxy auf Solr.
- Tenant-Operationen laufen über `solr-tenant.sh` (inkl. `sync-sot`).
- Solr schreibt in `solr_data`, Host-Logs und Backups.
- SolrCloud + Monitoring bleiben optional.

Hinweis: In diesem Repo wird bewusst nur die Docker-Instanz dargestellt (kein Ansible).

## Schnellstart

```bash
git clone https://github.com/Codename-Beast/solr-moodle-docker
cd solr-moodle-docker
cp .env.example .env
# Passwörter setzen (kein CHANGE_ME)
docker compose up -d --build
```

Healthcheck:

```bash
docker compose ps
curl -u "admin:<SOLR_ADMIN_PASSWORD>" "http://127.0.0.1:${SOLR_PORT:-8983}/solr/admin/info/system"
```

## Installationsprozess (code-nah)

1. `cp .env.example .env` und Pflichtpasswörter setzen.
2. `docker compose up -d --build` startet den Stack.
3. `solr-init` läuft einmalig und erzeugt Bootstrap/Security-Artefakte.
4. Erst danach startet `solr` (abhängig von erfolgreichem Init-Exit).
5. Verifikation über `docker compose ps` und `.../solr/admin/info/system`.

## Runtime-Prozess (code-nah)

- Zugriffspfad: Moodle -> Reverse Proxy (TLS) -> `127.0.0.1:${SOLR_PORT:-8983}`.
- Tenant-Verwaltung: `scripts/solr-tenant.sh` (`create/list/passwd/sync-sot`).
- SoT-Abgleich: `.env + tenants.env -> Solr API` via `sync-sot`.
- Persistenz: `solr_data` (Index/Cores/Security), Host-Logs, `solr_backups`.
- Optional: `SOLR_MODE=solrcloud` fuer Collections-basierten Betrieb.

## Multi-Tenant Basics

```bash
# Tenant anlegen
docker compose exec -T solr /opt/solr/scripts/solr-tenant.sh create schule_a --cores moodle_prod_a,moodle_test_a

# Liste
docker compose exec -T solr /opt/solr/scripts/solr-tenant.sh list

# Passwort rotieren
docker compose exec -T solr /opt/solr/scripts/solr-tenant.sh passwd schule_a

# Source-of-Truth Sync (.env + tenants.env -> Solr API)
docker compose exec -T solr /opt/solr/scripts/solr-tenant.sh sync-sot
```

## SolrCloud (optional)

In `.env`:

```bash
SOLR_MODE=solrcloud
```

Danach neu starten:

```bash
docker compose up -d --build
```

## Tests

```bash
./scripts/run-tests.sh
./scripts/test-moodle-documents.sh
```

## Wichtige Hinweise

- `SOLR_BIND=127.0.0.1` beibehalten, extern nur über Proxy.
- `tenants.env` enthält Secrets und bleibt unversioniert.
- Monitoring ist optional; Doku bleibt verfügbar, aber aktuell kein aktiver Ausbau.

## Struktur

- `config/managed-schema`
- `config/solrconfig.xml`
- `scripts/solr-tenant.sh`
- `scripts/run-tests.sh`
- `scripts/test-moodle-documents.sh`
- `docs/`
