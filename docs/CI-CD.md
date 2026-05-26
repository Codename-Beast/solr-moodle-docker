# CI/CD — solr-moodle-docker

## GitHub Actions

Workflow: [.github/workflows/solr-testing.yml](../.github/workflows/solr-testing.yml)

Läuft automatisch bei Push/PR auf `main`, `feature/*` und `release*`.

### Pipeline-Stages

| Stage | Job | Was geprüft wird |
|-------|-----|-------------------|
| Lint | Code Quality Checks | shellcheck, hadolint, yamllint |
| Security | Security Vulnerability Scan | Trivy CVE-Scan (init + Solr Image) |
| Test | Solr Tests | Auth, Permissions, Tika, Multi-Tenant, Placeholder-Schutz |
| Test | SolrCloud Mode Tests | Collections API, echte Isolation, Neustart-Persistenz |

### Solr Tests (Standalone)

- Container-Start + Healthcheck
- Admin/Support-Authentifizierung
- Tenant anlegen via `solr-tenant.sh create`
- Tenant-User kann eigene Cores lesen/schreiben
- Tika `/update/extract` — harter Fehler wenn nicht funktional
- Placeholder-Passwort-Schutz (CHANGE_ME wird abgewiesen)
- Multi-Tenant-Isolation (403 beim Zugriff auf fremden Core)

### SolrCloud Tests

- `SOLR_MODE=solrcloud` — eingebetteter ZooKeeper
- Security Bootstrap via ZooKeeper
- Collections API statt Core Admin API
- Echte Collection-Level-Isolation (403 ohne Proxy)
- Moodle-Dokument indexieren + Neustart-Persistenz
- Tika `/update/extract` im SolrCloud-Modus

---

## GitLab CI

Pipeline: [.gitlab-ci.yml](../.gitlab-ci.yml)

### Runner-Konfiguration

Runner-Tag via GitLab-Variable konfigurieren:

```
Settings → CI/CD → Variables → CI_RUNNER_TAG = <euer Runner-Name>
```

Default: `docker` (für lokale Testinstanz).

Anforderungen:
- Docker-Socket-Mount (`/var/run/docker.sock`)
- Mind. 4 GB RAM
- `pull_policy = if-not-present` in `config.toml`

### Stages

| Stage | Jobs |
|-------|------|
| lint | shellcheck, docker compose config, bash -n |
| test | feature-full-test (unit-only im 10min-Limit) |

---

## Lokale Tests

```bash
# Stack starten
docker compose up -d --build

# Unit-Tests
./scripts/run-tests.sh --unit-only

# Integration-Tests
./scripts/run-tests.sh --integration-only --no-cleanup

# Sicherheits-Tests
./scripts/run-tests.sh --security-only --no-cleanup

# Moodle-Dokument-Indexierung
./scripts/test-moodle-documents.sh

# Alles
./scripts/run-tests.sh

# Aufräumen
docker compose down -v
```

---

## Troubleshooting

**Init-Container schlägt fehl:**
```bash
docker compose logs solr-init
# Häufig: SOLR_ADMIN_PASSWORD nicht gesetzt oder noch CHANGE_ME
```

**Solr antwortet nicht:**
```bash
docker compose logs solr
docker inspect --format='{{.State.Health.Status}}' solr-solr
```

**Tika-Test schlägt fehl:**
```bash
# Prüfen ob SOLR_MODULES=extraction in docker-compose.yml gesetzt ist
grep SOLR_MODULES docker-compose.yml
```

**Permission Denied bei Scripts:**
```bash
chmod +x scripts/*.sh
```
