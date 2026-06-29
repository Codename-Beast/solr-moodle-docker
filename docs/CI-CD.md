# CI/CD — solr-moodle-docker

Die Pipeline prüft den Stack so, wie Moodle ihn nutzt: Auth, Tenant-Rechte, SolrCloud-Persistenz und Dokumentsuche.

---

## GitHub Actions

| Job | Inhalt |
|---|---|
| Lint | ShellCheck und Compose-Validierung |
| Security Scan | Solr-Image bauen und mit Trivy prüfen |
| Standalone Core Tests | Standalone-Modus, Tenant-CLI, Auth, Tika |
| SolrCloud Tests | Collections, ACLs, Drift, Restart, Scale-Test |

Teure Tests laufen nur bei Commits mit `[run-ci]` oder manuell per Workflow Dispatch.

---

## Lokale Checks

```bash
bash -n scripts/*.sh setup.sh apache/generate-apache-config.sh nginx/generate-nginx-config.sh init/powerinit.sh
shellcheck scripts/*.sh setup.sh apache/generate-apache-config.sh nginx/generate-nginx-config.sh init/powerinit.sh
docker compose config --quiet
```

Proxy-Compose prüfen:

```bash
COMPOSE_DISABLE_ENV_FILE=1 PROXY_HOSTNAME=kundendomain.de PROXY_SOLR_HOSTNAME=solr.kundendomain.de \
  docker compose -f docker-compose.proxy.yml --profile caddy config --quiet

COMPOSE_DISABLE_ENV_FILE=1 PROXY_HOSTNAME=kundendomain.de PROXY_SOLR_HOSTNAME=solr.kundendomain.de \
  docker compose -f docker-compose.proxy.yml --profile nginx config --quiet
```

---

## Testläufe

```bash
./scripts/run-tests.sh --unit-only
./scripts/run-tests.sh --tenant
./scripts/run-tests.sh --tenant-commands
./scripts/run-tests.sh --cloud --tenant --tenant-scale --no-performance
./scripts/test-moodle-documents.sh
```

`--mode-switch` ist ein lokaler Helfer für Wechsel zwischen Standalone und SolrCloud.

---

## Typische Meldungen

| Meldung | Bedeutung |
|---|---|
| `Security reload not confirmed after 30s` | Solr hat die neue Security-Datei nicht rechtzeitig übernommen |
| `Tenant create failed` | Tenant, Core/Collection oder ACLs konnten nicht angelegt werden |
| `healthcheck command` fehlgeschlagen | Solr, Auth oder Bootstrap-Zustand passt nicht |
| `drift-detect` meldet Fehler | Runtime und `tenants.env` sind nicht synchron |

---

## GitLab

GitLab nutzt dieselben Grundprüfungen. Der Runner braucht Docker Compose und Zugriff auf die benötigten Images.

Mehr dazu:

- [GITLAB-QUICKSTART.md](GITLAB-QUICKSTART.md)
- [GITLAB-CI-CD-SETUP.md](GITLAB-CI-CD-SETUP.md)
