# GitLab Quickstart

Kurzer Weg, um die GitLab-Pipeline für den Stack zu starten.

---

## Voraussetzungen

| Punkt | Wert |
|---|---|
| Runner | Docker-fähig |
| Compose | Docker Compose V2 |
| Zugriff | Registry und GitLab erreichbar |
| Branch | enthält `.gitlab-ci.yml` |

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

## Jobs

| Job | Wann | Inhalt |
|---|---|---|
| `main-minimal` | `main` | kurze Shell-/Compose-Prüfung |
| `feature-lint` | Feature- und Release-Branches | Shell-/Compose-Prüfung |
| `feature-full-test` | Feature- und Release-Branches | voller Stack-Test in SolrCloud |

---

## Wenn etwas rot ist

1. Job-Log öffnen.
2. Erste echte Fehlermeldung suchen.
3. Container-Logs prüfen.
4. Lokal nachstellen.
5. Fixen und erneut pushen.
