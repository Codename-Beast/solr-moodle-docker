# GitLab CI/CD Quick Start

Setup-Zeit: 5 Minuten.

---

## Fuer GitLab.com

### 1. Repository pushen

```bash
git remote add gitlab https://gitlab.com/DEIN-USERNAME/solr-moodle-docker.git
git push -u gitlab main
```

### 2. Shared Runners aktivieren

**Settings → CI/CD → Runners** → "Enable shared runners for this project" einschalten.

### 3. Pipeline laeuft

**Build → Pipelines** — erste Pipeline sollte laufen. Dauert ~8-10 Minuten.

### 4. Badge im README (optional)

```markdown
[![Pipeline Status](https://gitlab.com/DEIN-USERNAME/solr-moodle-docker/badges/main/pipeline.svg)](https://gitlab.com/DEIN-USERNAME/solr-moodle-docker/-/pipelines)
```

---

## Was bei jedem Push getestet wird

| Stage | Dauer | Was |
|-------|-------|-----|
| Validate | ~30s | Syntax & Struktur |
| Build | 1-2 min | Container Images |
| Test | 6-8 min | Unit, Integration, Moodle Tests |
| Security | ~1 min | Permissions, Secrets |

Gesamt: ~10 Minuten.

---

## Haeufige Probleme

**"No runners available":** Settings → CI/CD → Runners → Shared Runners einschalten.

**Tests schlagen fehl:** Logs unter Build → Pipelines → Job-Name.

**Pipeline zu langsam:** 8-10 Minuten ist normal (Docker-Container-Startup).

---

## Mehr Details

Fuer Self-Hosted GitLab, Runner-Konfiguration, Troubleshooting: [GITLAB-CI-CD-SETUP.md](GITLAB-CI-CD-SETUP.md)

Fragen: [GitHub Issues](https://github.com/Codename-Beast/solr-moodle-docker/issues)
