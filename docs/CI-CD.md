# 🧪 CI/CD — solr-moodle-docker

Die Pipeline prüft den Docker-Stack in Standalone und SolrCloud. Wichtig ist nicht nur, ob Container starten, sondern ob Moodle-relevante Pfade wirklich funktionieren.

---

## Jobs

| Job | Prüft |
|---|---|
| Lint | Shell-Syntax, ShellCheck, Compose-Konfiguration |
| Security Scan | einfache Security- und Secret-Prüfungen |
| Standalone Core Tests | Core-Modus, Auth, Tenant-Befehle, Tika |
| SolrCloud Tests | Collections, ZooKeeper-Persistenz, ACL-Reihenfolge, Drift |

---

## Lokale Checks

```bash
bash -n scripts/*.sh setup.sh apache/generate-apache-config.sh init/powerinit.sh
shellcheck scripts/*.sh setup.sh apache/generate-apache-config.sh init/powerinit.sh
docker compose config --quiet
```

Unit-Tests:

```bash
./scripts/run-tests.sh --cloud --no-performance --no-cleanup
```

Hinweis: `--mode-switch` bleibt ein lokaler Helfer, wird aber nicht in der GitLab-Pipeline ausgeführt.

Tenant-Tests:

```bash
./scripts/run-tests.sh --tenant
```

Nur Tenant-CLI-Vertrag:

```bash
./scripts/run-tests.sh --tenant-commands
```

---

## Was die Pipeline absichert

- `solr-tenant.sh passwd --password` funktioniert mit expliziten Passwörtern.
- alte Passwörter werden nach Rotation abgelehnt.
- neue Passwörter funktionieren gegen den Solr-Endpoint.
- `rebuild-permissions` hält die Fallback-Permission `all` am Ende.
- Tika indexiert Moodle-Dokumente über `/update/extract`.
- SolrCloud-Daten überleben einen Restart.

---

## GitLab

GitLab nutzt dieselben Grundchecks. Der Runner muss Docker Compose ausführen können und Zugriff auf die benötigten Images haben.

Details stehen in:

- [GITLAB-CI-CD-SETUP.md](GITLAB-CI-CD-SETUP.md)
- [GITLAB-QUICKSTART.md](GITLAB-QUICKSTART.md)
