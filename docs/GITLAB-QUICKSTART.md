# GitLab CI/CD Quick Start

** Setup-Zeit: 5 Minuten**

---

##  Schnellstart für GitLab.com

###  Repository zu GitLab pushen ( Min)

```bash
# Projekt zu GitLab pushen
git remote add gitlab https://gitlab.com/DEIN-USERNAME/solr-moodle-docker.git
git push -u gitlab main
```

###  Shared Runners aktivieren ( Min)

. Gehe zu deinem Projekt auf GitLab.com
. **Settings → CI/CD → Runners**
. Aktiviere **"Enable shared runners for this project"**

![Enable Runners](https://docs.gitlab.com/ee/ci/img/shared_runners_v_5.png)

###  Pipeline läuft automatisch! ( Min)

. Gehe zu **Build → Pipelines**
. Siehst du die erste Pipeline laufen
. Warte ~8- Minuten bis alle Tests durch sind

![Pipeline Success](https://docs.gitlab.com/ee/ci/img/pipeline_success.png)

###  Badge im README (optional)

Füge Pipeline-Status Badge ein:

```markdown
[![Pipeline Status](https://gitlab.com/DEIN-USERNAME/solr-moodle-docker/badges/main/pipeline.svg)](https://gitlab.com/DEIN-USERNAME/solr-moodle-docker/-/pipelines)
```

---

##  Das war's!

**Jetzt automatisch bei jedem Push:**
-  Syntax-Validierung
-  Container-Build
-  Unit Tests
-  Integration Tests
-  Moodle Document Tests
-  Security Tests
-  Secret Scanning

---

##  Detaillierte Anleitung

Für Self-Hosted GitLab, Runner-Konfiguration, Troubleshooting:
→ [GITLAB-CI-CD-SETUP.md](GITLAB-CI-CD-SETUP.md)

---

## 🐛 Häufige Probleme

### "No runners available"
→ **Settings → CI/CD → Runners** → "Enable shared runners" aktivieren

### Tests schlagen fehl
→ Logs ansehen: **Build → Pipelines → Job-Name** klicken

### Pipeline zu langsam
→ Normal: 8- Minuten (Docker-Container-Startup)

---

## 🎓 Was wird getestet?

| Stage | Dauer | Was |
|-------|-------|-----|
| **Validate** | 0s | Syntax & Struktur |
| **Build** | -min | Container Images |
| **Test** | 6-8min | Unit, Integration, Moodle Tests |
| **Security** | min | Permissions, Secrets |

**Total:** ~0 Minuten

---

## 📞 Hilfe benötigt?

→ [Vollständige Dokumentation](GITLAB-CI-CD-SETUP.md)
→ [GitHub Issues](https://github.com/Codename-Beast/solr-moodle-docker/issues)
