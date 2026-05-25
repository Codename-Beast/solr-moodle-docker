> Hinweis (Release 1.0): Diese Doku wurde vereinfacht und auf den aktuellen Stand gebracht.
> Monitoring ist optional und aktuell nicht im aktiven Ausbau.

# CI/CD Pipeline

Tests laufen bei jedem Push — GitHub Actions und GitLab CI.

---

## GitHub Actions

Workflow: [.github/workflows/solr-testing.yml](../.github/workflows/solr-testing.yml)

Laeuft automatisch bei Push/PR auf `main` oder `feature/*`.

### Stages

| Stage | Was geprueft wird |
|-------|-------------------|
| Code Quality | shellcheck, hadolint, yamllint |
| Security Scan | Trivy (CVE-Scan beider Images) |
| Solr Tests | Standalone: Auth, Permissions, Tika, Multi-Tenant |
| SolrCloud Tests | Collections API, echte Isolation, Dokument-Indexierung, Neustart-Persistenz |

### Standalone-Tests

- Container-Start + Healthcheck
- Admin/Support-Auth korrekt
- Tenant anlegen (`solr-tenant.sh create`)
- Tenant-User kann eigene Cores lesen/schreiben
- Tika `/update/extract` funktioniert (harter Fehler)
- Schema-API zugaenglich
- Backup-Script laeuft durch

### SolrCloud-Tests

- `SOLR_MODE=solrcloud` — eingebetteter ZooKeeper
- Security Bootstrap (ZK-Initialisierungsproblem automatisch behoben)
- Collections API statt Core Admin API
- Echte Collection-Level-Isolation (403 ohne Proxy)
- Moodle-Dokument mit allen Pflichtfeldern indexierbar
- Dokument ueberlebt Container-Neustart
- Tika `/update/extract` funktioniert

---

## GitLab CI/CD

Pipeline in `.gitlab-ci.yml`. Gleiche Stages wie GitHub Actions.

Runner-Anforderungen:
- Tags: `[docker, privileged]`
- Mind. 4 GB RAM
- Docker-in-Docker (`DOCKER_DRIVER: overlay2`)

---

## Lokale Tests

```bash
# Stack starten
docker compose build --no-cache solr-init
docker compose up -d

# Einzeln
./scripts/run-tests.sh --unit-only
./scripts/run-tests.sh --integration-only
./scripts/run-tests.sh --security-only

# Alles
./scripts/run-tests.sh

# Aufraeumen
docker compose down -v
```

---

## Troubleshooting

**"Init-Container schlaegt fehl":**
```bash
docker compose logs solr-init
# Oft: .env fehlt oder SOLR_ADMIN_PASSWORD nicht gesetzt
```

**"Solr antwortet nicht":**
```bash
docker compose logs solr
docker inspect --format='{{.State.Health.Status}}' solr-solr
```

**"Tika-Test schlaegt fehl":**
Pruefen ob `SOLR_MODULES=extraction` in `docker-compose.yml` gesetzt ist.
Das Modul ladet Tika auf Server-Ebene — kein separater Container noetig.

**"Permission Denied bei Scripts":**
```bash
chmod +x scripts/*.sh
```

---

## Support

Pipeline-Logs anschauen, lokal testen, Issue auf GitHub/GitLab erstellen.


## solr-helper-pro local UI notes
- `scripts/solr-helper-pro.py` is treated as local-only operator tooling in this workspace.
- Current UI behavior: create button in list header, selection-driven right panel (host+container info + live logs), tenant-capable column in server list, and detail screen with inline config/user/log operations plus Solr runtime/schema summary.
- Theme direction: dark black/orange with stronger borders and accents.
