# 🚀 GitLab Quickstart

Kurzer Ablauf, um die GitLab-Pipeline für den Docker-Stack laufen zu lassen.

---

## Voraussetzungen

| Punkt | Wert |
|---|---|
| Runner | Docker-fähig |
| Compose | Docker Compose V2 |
| Repository | Branch mit `.gitlab-ci.yml` |
| Netzwerk | Zugriff auf Registry und GitLab |

---

## Runner prüfen

```bash
gitlab-runner status
docker version
docker compose version
```

---

## Pipeline starten

```bash
git push gitlab <branch>
```

Oder im GitLab UI:

```text
CI/CD -> Pipelines -> Run pipeline
```

---

## Erwartete Jobs

| Job | Ergebnis |
|---|---|
| lint | Shell/Compose ok |
| unit | Unit-Tests ok |
| standalone | Stack läuft im Core-Modus |
| solrcloud | Stack läuft im SolrCloud-Modus |

---

## Wenn ein Job rot ist

1. Job-Log öffnen.
2. Erste echte Fehlermeldung suchen, nicht nur den letzten Cleanup-Block.
3. Bei Stack-Fehlern Container-Logs prüfen.
4. Fix lokal nachstellen.
5. Pushen und Pipeline erneut laufen lassen.
