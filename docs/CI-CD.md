# 🧪 CI/CD — solr-moodle-docker

Diese Pipeline prüft den Stack nicht nur auf „Container startet“, sondern auf das, was Moodle wirklich braucht: Login, Tenant-Rechte, SolrCloud-Persistenz und Dokumentsuche.

---

## Was läuft in der CI?

| Job | Was geprüft wird |
|---|---|
| Lint | Shell-Syntax, ShellCheck, Compose-Datei |
| Security Scan | einfache Sicherheitschecks und Image-Scan |
| Standalone Core Tests | Standalone-Modus, Tenant-Befehle, Auth, Tika |
| SolrCloud Tests | Collections, ACLs, Drift, Persistenz, Restart-Verhalten |

---

## Lokale Checks

```bash
bash -n scripts/*.sh setup.sh apache/generate-apache-config.sh init/powerinit.sh
shellcheck scripts/*.sh setup.sh apache/generate-apache-config.sh init/powerinit.sh
docker compose config --quiet
```

---

## Die wichtigsten Testläufe

```bash
./scripts/run-tests.sh --unit-only
./scripts/run-tests.sh --tenant
./scripts/run-tests.sh --tenant-commands
./scripts/test-moodle-documents.sh
```

`--mode-switch` ist ein lokaler Helfer für den Wechsel zwischen Standalone und SolrCloud. Er ist bewusst nicht Teil der GitLab-Pipeline.

---

## Was die Meldungen meist bedeuten

- `Security reload not confirmed after 30s` → Solr hat die neue Security-Datei nicht rechtzeitig übernommen.
- `Tenant create failed` → Tenant, Core oder ACLs konnten nicht sauber angelegt werden.
- `healthcheck command` fehlgeschlagen → Solr antwortet nicht sauber oder der Bootstrap-Zustand passt nicht.
- `drift-detect` meldet Fehler → Runtime und `tenants.env` sind nicht mehr synchron.

---

## GitLab

GitLab nutzt dieselben Grundprüfungen. Der Runner muss Docker Compose ausführen können und Zugriff auf die benötigten Images haben.

Mehr dazu:

- [GITLAB-QUICKSTART.md](GITLAB-QUICKSTART.md)
- [GITLAB-CI-CD-SETUP.md](GITLAB-CI-CD-SETUP.md)
