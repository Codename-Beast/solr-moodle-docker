# GitLab CI/CD Quick Start

**⏱️ Setup-Zeit: 5 Minuten**

---

## 🚀 Schnellstart für GitLab.com

### 1️⃣ Repository zu GitLab pushen (2 Min)

```bash
# Projekt zu GitLab pushen
git remote add gitlab https://gitlab.com/DEIN-USERNAME/solr-moodle-docker.git
git push -u gitlab main
```

### 2️⃣ Shared Runners aktivieren (1 Min)

1. Gehe zu deinem Projekt auf GitLab.com
2. **Settings → CI/CD → Runners**
3. Aktiviere **"Enable shared runners for this project"**

![Enable Runners](https://docs.gitlab.com/ee/ci/img/shared_runners_v14_5.png)

### 3️⃣ Pipeline läuft automatisch! (2 Min)

1. Gehe zu **Build → Pipelines**
2. Siehst du die erste Pipeline laufen
3. Warte ~8-12 Minuten bis alle Tests durch sind

![Pipeline Success](https://docs.gitlab.com/ee/ci/img/pipeline_success.png)

### 4️⃣ Badge im README (optional)

Füge Pipeline-Status Badge ein:

```markdown
[![Pipeline Status](https://gitlab.com/DEIN-USERNAME/solr-moodle-docker/badges/main/pipeline.svg)](https://gitlab.com/DEIN-USERNAME/solr-moodle-docker/-/pipelines)
```

---

## ✅ Das war's!

**Jetzt automatisch bei jedem Push:**
- ✅ Syntax-Validierung
- ✅ Container-Build
- ✅ Unit Tests
- ✅ Integration Tests
- ✅ Moodle Document Tests
- ✅ Security Tests
- ✅ Secret Scanning

---

## 📚 Detaillierte Anleitung

Für Self-Hosted GitLab, Runner-Konfiguration, Troubleshooting:
→ [GITLAB-CI-CD-SETUP.md](GITLAB-CI-CD-SETUP.md)

---

## 🐛 Häufige Probleme

### "No runners available"
→ **Settings → CI/CD → Runners** → "Enable shared runners" aktivieren

### Tests schlagen fehl
→ Logs ansehen: **Build → Pipelines → Job-Name** klicken

### Pipeline zu langsam
→ Normal: 8-12 Minuten (Docker-Container-Startup)

---

## 🎓 Was wird getestet?

| Stage | Dauer | Was |
|-------|-------|-----|
| **Validate** | 30s | Syntax & Struktur |
| **Build** | 1-2min | Container Images |
| **Test** | 6-8min | Unit, Integration, Moodle Tests |
| **Security** | 2min | Permissions, Secrets |

**Total:** ~10 Minuten

---

## 📞 Hilfe benötigt?

→ [Vollständige Dokumentation](GITLAB-CI-CD-SETUP.md)
→ [GitHub Issues](https://github.com/Codename-Beast/solr-moodle-docker/issues)
