# solr-moodle-docker

Einfacher Solr-Stack für Moodle Global Search (Standalone + optional SolrCloud) mit Multi-Tenant.

## Schnellstart

```bash
git clone https://github.com/Codename-Beast/solr-moodle-docker
cd solr-moodle-docker
cp .env.example .env
# WICHTIG: Passwörter in .env setzen (kein CHANGE_ME)
docker compose up -d --build
```

Prüfen:

```bash
docker compose ps
curl -u "admin:<SOLR_ADMIN_PASSWORD>" "http://127.0.0.1:${SOLR_PORT:-8983}/solr/admin/info/system"
```

## Was der Stack macht

- Solr inkl. `security.json` Bootstrap aus `.env` + `tenants.env`
- Tika `/update/extract` für Datei-Indexierung (PDF, Office, Bilder-Metadaten)
- Tenant-Verwaltung über `scripts/solr-tenant.sh`
- Tests für Standalone + SolrCloud

## Multi-Tenant Befehle

```bash
# Tenant anlegen
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh create schule_a --cores moodle_prod_a

# Liste
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh list

# Passwort rotieren
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh passwd schule_a

# Source-of-Truth abgleichen (.env + tenants.env -> API)
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh sync-sot
```

## SolrCloud (optional)

In `.env` setzen:

```bash
SOLR_MODE=solrcloud
```

Dann neu starten:

```bash
docker compose up -d --build
```

## Tests

```bash
./scripts/run-tests.sh
./scripts/test-moodle-documents.sh
```

## Wichtige Hinweise

- `SOLR_BIND` sollte `127.0.0.1` bleiben (Zugriff extern über Proxy).
- `tenants.env` enthält Secrets und darf nicht in Git.
- Monitoring-Dokumentation ist vorhanden, wird aber in diesem Repo nicht aktiv weiterentwickelt.

## Relevante Dateien

- `docker-compose.yml`
- `config/managed-schema`
- `config/solrconfig.xml`
- `scripts/solr-tenant.sh`
- `scripts/run-tests.sh`
- `scripts/test-moodle-documents.sh`

## Weitere Doku

- `docs/architecture.md`
- `docs/CI-CD.md`
- `docs/monitoring.md`
- `CHANGELOG.md`
