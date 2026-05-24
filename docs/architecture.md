# Architektur — solr-moodle-docker

## Ziel
Containerisierter Solr-Stack fuer Moodle Global Search mit Tenant-Management, Security-Bootstrap und optionalem SolrCloud-Modus.

## Komponenten

- `docker-compose.yml`
  - `solr-init` (Init/Bootstrap)
  - `solr` (Runtime)
- `init/powerinit.sh`
  - erzeugt/aktualisiert `security.json`
  - initialisiert Kerndaten und Rollen
- `scripts/solr-tenant.sh`
  - Tenant-Lifecycle: create/delete/enable/passwd/core-add/core-remove/apply/export/caddy-config
- `config/managed-schema`
  - Moodle-Felder + `solr_filecontent` fuer Tika-Extraktion
- `config/solrconfig.xml`
  - `/update/extract` Handler; `fmap.content=solr_filecontent`

## Laufzeitdaten

- `.env` (Admin/Support, Ports, Modus)
- `tenants.env` (Tenant-Zustand + Core-Zuordnung)
- `/var/solr/data` (Cores/Collections + Security)

## Betriebsmodi

### Standalone
- Core Admin API
- Tenant-Isolation ueber Security + Proxy-Routing

### SolrCloud
- Collections API + embedded ZK
- serverseitig Collection-basierte Isolation

## Request-Flows

1) Admin/API
- Client -> Proxy (optional) -> Solr AuthN/AuthZ -> Core/Collection APIs

2) Moodle File Indexing
- Moodle -> `/update/extract`
- Tika extrahiert Text -> Mapping nach `solr_filecontent`
- Suchanfragen treffen `text_general` Analyzer

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

## Grenzen

- Kein Multi-Node-Orchestrator
- Kein externer ZK-Cluster-Manager im Projekt selbst
- Proxy-/TLS-Produktionshärtung bleibt Umgebungsaufgabe
