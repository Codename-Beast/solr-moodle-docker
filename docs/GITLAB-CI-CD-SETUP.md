# GitLab CI/CD Setup

Notizen für Runner, die den Docker-Stack wirklich starten. Reine Shell-Runner reichen dafür nicht.

---

## Runner

| Einstellung | Empfehlung |
|---|---|
| Executor | shell oder docker mit Docker-Zugriff |
| Docker | Engine + Compose V2 |
| Tags | passend zur `.gitlab-ci.yml` |
| Storage | genug Platz für Solr-Images und Testdaten |

---

## System prüfen

```bash
docker version
docker compose version
gitlab-runner verify
```

---

## Repository anbinden

```bash
git remote add gitlab <gitlab-repo-url>
git push gitlab <branch>
```

Die Pipeline startet beim Push oder manuell über die GitLab-Oberfläche.

---

## Typische Fehler

| Symptom | Ursache | Fix |
|---|---|---|
| `docker: permission denied` | Runner-User darf Docker nicht nutzen | Gruppe/Rechte prüfen |
| Compose nicht gefunden | altes Docker Setup | Compose V2 installieren |
| Port belegt | alter Test-Stack läuft noch | `docker compose down -v` im Workspace |
| Image alt | Cache greift | Build erzwingen oder Cache leeren |

---

## Logs

```bash
docker compose ps
docker compose logs --no-color
```
