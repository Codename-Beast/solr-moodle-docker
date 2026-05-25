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

## Multi-Tenant Basics

```bash
# Tenant anlegen
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh create schule_a --cores moodle_prod_a,moodle_test_a

# Liste
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh list

# Passwort rotieren
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh passwd schule_a

# Source-of-Truth Sync (.env + tenants.env -> Solr API)
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh sync-sot
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
