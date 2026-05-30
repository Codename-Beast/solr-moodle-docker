> Hinweis (Release 1.0): Diese Doku wurde vereinfacht und auf den aktuellen Stand gebracht.
> Monitoring ist optional und aktuell nicht im aktiven Ausbau.

# Architektur — solr-moodle-docker

## Ziel
Containerisierter Solr-Stack fuer Moodle Global Search mit globalisiertem Init-Container, Security-Bootstrap, Default-Configset aus `eLeDia-config/` und SolrCloud-Runtime.

## Architekturdiagramm

```
┌─────────────────────────────────────────────────────────────┐
│  Umgebung                                                    │
│                                                             │
│  Projektdateien                                              │
│  ├── docker-compose.yml                                      │
│  ├── .env                                                    │
│  ├── tenants.env                                             │
│  ├── init/powerinit.sh                                       │
│  ├── scripts/solr-tenant.sh                                  │
│  ├── eLeDia-config/managed-schema                            │
│  └── eLeDia-config/solrconfig.xml                            │
└──────────────────────────┬──────────────────────────────────┘
│ docker compose up -d
▼
┌─────────────────────────────────────────────────────────────┐
│  Docker Network: ${INSTANCE_NAME}-network                    │
│                                                             │
│  ┌──────────────────────────┐  bootstrap  ┌───────────────┐ │
│  │  eLeDia-solr-init        │────────────▶│  solr (9.x)   │ │
│  │  (global init worker)    │             │  /solr        │ │
│  │  writes security.json    │             │  AuthN/AuthZ  │ │
│  │  uploads default config  │             │  + collections │ │
│  └──────────────────────────┘             └──────┬────────┘ │
│                                                  │          │
│                                       /update/extract (Tika)│
│                                                  │          │
│                                       fmap.content=solr_filecontent
└──────────────────────────────────────────────┬──────────────┘
│
bind 127.0.0.1:${SOLR_PORT}
│
▼
┌─────────────────────────────────────────────────────────────┐
│  Optional Reverse Proxy (Apache/Caddy/Nginx)                │
│  HTTPS 443 -> /solr -> 127.0.0.1:${SOLR_PORT}              │
└─────────────────────────────────────────────────────────────┘
```

## Komponenten

- `docker-compose.yml`
- `eLeDia-solr-init` (globaler Init/Bootstrap)
- `solr` (Runtime)
- `init/powerinit.sh`
  - erzeugt/aktualisiert `security.json`
  - setzt Default-Configsets (`eLeDia-moodle-tenant` und `_default`) aus `eLeDia-config/`
  - verarbeitet optionale Multi-Target-Metadaten (`INIT_TARGETS`)
- `scripts/solr-tenant.sh`
  - Tenant-Lifecycle: create/delete/enable/passwd/core-add/core-remove/apply/export/caddy-config
- `eLeDia-config/managed-schema`
  - Moodle-Felder + `solr_filecontent` fuer Tika-Extraktion
- `eLeDia-config/solrconfig.xml`
  - `/update/extract` Handler; `fmap.content=solr_filecontent`

## Laufzeitdaten

- `.env` (Admin/Support, Ports, Modus)
- `tenants.env` (Tenant-Zustand + Core-Zuordnung)
- `/var/solr/data` (Cores/Collections + Security)
- `${ELEDIA_LOG_ROOT:-/var/log/eledia/solr}/${INSTANCE_NAME}` (init/setup/install/runtime Logs auf Host)

## Betriebsmodi

### Standalone
- Core Admin API
- Tenant-Isolation ueber Security + Proxy-Routing

### SolrCloud
- Collections API + embedded ZK
- serverseitig Collection-basierte Isolation

## Tika Marker Hinweis (wichtig)

`text_general` nutzt `StandardTokenizerFactory`; Tokens mit `_` werden zerlegt.
Darum kann ein Query auf den exakten Marker `ELEDIA_TIKA_TEST_MARKER` je nach Analyzer-/Queryparser-Kontext 0 Treffer liefern, obwohl die PDF-Inhalte korrekt indexiert wurden.

Deshalb sind robuste Tests zweistufig:
- Marker/Fallback-Query
- semantische Inhaltsquery (`moodle solr tika`) als Pflichtcheck

## Tenant-Lifecycle (technisch)

- create: Tenant + Cores + Permissions
- core-remove/core-add: feingranulare Core-Rechte
- delete: deaktiviert Tenant (Daten bleiben erhalten)
- enable: reaktiviert Tenant
- apply: reconciled Zustand aus `tenants.env`

## Status

- Multi-Node-Orchestrierung und externer ZK-Cluster-Manager sind nicht Teil dieses Repositories.
- Proxy/TLS-Härtung wird über die jeweilige Zielumgebung umgesetzt.
