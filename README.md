# solr-moodle-docker

Lokale Solr 9.10.1 Umgebung fuer Moodle Global Search (Standalone + SolrCloud) mit Multi-Tenant Verwaltung.

## TL;DR

```bash
git clone https://github.com/Codename-Beast/solr-moodle-docker
cd solr-moodle-docker
cp .env.example .env
# WICHTIG: sichere Passwoerter setzen (nicht CHANGE_ME)
docker compose up -d --build
```

Healthcheck:

```bash
docker compose ps
curl -u "admin:<SOLR_ADMIN_PASSWORD>" "http://127.0.0.1:${SOLR_PORT:-8983}/solr/admin/info/system"
```

## Was ist neu / wichtig

- SolrCloud Security-Bootstrap ueber `scripts/solr-cloud-entrypoint.sh` (security.json in ZK)
- Setup idempotent: bestehende `.env` wird bei Re-Run nicht ueberschrieben
- `tenants.env` Rechte fuer Solr UID 8983
- Placeholder-Passwoerter werden fail-fast abgelehnt
- Ports bleiben dynamisch (`SOLR_PORT`) in Compose + Healthchecks
- GitHub Actions + GitLab CI auf Multi-Tenant/SolrCloud Tests ausgerichtet

## Wichtige Dateien

- `.env.example` -> Runtime-Parameter
- `docker-compose.yml` -> Solr + Init
- `init/powerinit.sh` -> erzeugt `security.json` aus `.env` + `tenants.env`
- `scripts/solr-tenant.sh` -> Tenant Verwaltung
- `scripts/run-tests.sh` -> lokale Test-Suite
- `config/managed-schema` -> Moodle Felder
- `config/solrconfig.xml` -> Handler/Caches/Commit-Verhalten

## Multi-Tenant Basics

Tenant erstellen:

```bash
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh create schule_a --cores moodle_prod_a,moodle_test_a
```

Liste:

```bash
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh list
```

Passwort rotieren:

```bash
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh passwd schule_a
```

Idempotent aus `tenants.env` anwenden:

```bash
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh apply
```

## SolrCloud aktivieren

```bash
# .env
SOLR_MODE=solrcloud
```

Danach:

```bash
docker compose up -d --build
curl -u "admin:<SOLR_ADMIN_PASSWORD>" "http://127.0.0.1:${SOLR_PORT:-8983}/solr/admin/collections?action=LIST&wt=json"
```

## Tests

Alles:

```bash
./scripts/run-tests.sh
```

Nur Teilbereiche:

```bash
./scripts/run-tests.sh --unit-only
./scripts/run-tests.sh --integration-only --no-cleanup
./scripts/run-tests.sh --security-only --no-cleanup
./scripts/run-tests.sh --tenant
./scripts/run-tests.sh --cloud
```

## CI

GitHub Actions:
- `.github/workflows/solr-testing.yml`
- Lint, Security Scan, Standalone Tests, SolrCloud Tests

GitLab CI:
- `.gitlab-ci.yml`
- Docker-in-Docker (DinD) fuer reproduzierbare Runner ohne Host-Socket-Abhaengigkeit

## Solr Doku-basierte Tweaks (bereits umgesetzt)

- `/update/extract` ist aktiv (ExtractingRequestHandler)
- Tika-Metadaten werden per `uprefix=ignored_` abgefangen
- `fmap.content=solr_filecontent` mappt extrahierten Datei-Text gezielt ins Moodle-Dateifeld
- `autoSoftCommit` + `autoCommit` sind fuer NRT-Suche gesetzt
- CaffeineCache ist fuer Query-Caches aktiv

Hinweis: grosse Uploads steuern ueber `multipartUploadLimitInKB` in `solrconfig.xml`.

## Betrieb

```bash
docker compose logs -f solr
docker compose restart
docker compose down
docker compose down -v
```

## Sicherheit

- Bind nur lokal: `SOLR_BIND=127.0.0.1`
- BasicAuth aktiv (admin/support/tenant)
- `SOLR_MODULES=extraction` fuer Moodle File Indexing
- Hardening Flags in `SOLR_OPTS`
- `tenants.env` enthaelt Secrets -> nicht committen

## Ansible Rolle

Passend dazu:
- `ansible-role-solr`

Syntaxcheck lokal:

```bash
cd /home/bernd/ansible-role-solr
ansible-playbook -i .ci/ansible/test-inventory/hosts \
  -e @.ci/ansible/test-inventory/host_vars/localhost.yml \
  -e "hosts=localhost" \
  examples/install_solr.yml --syntax-check
```

## Kompatibilitaet zur Ansible-Rolle

| solr-moodle-docker | ansible-role-solr | Hinweis |
|---|---|---|
| v2.3.2 | 1.9.8 - 1.9.10 (Default) | empfohlene Kombination |
| v3.x | nur mit explizitem `solr_repo_version` Override | vor Einsatz Tenant/Auth-Flow testen |
