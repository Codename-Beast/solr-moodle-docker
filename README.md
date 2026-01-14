# Solr für Moodle

**Developer:** BSC Bernd Schreistetter | **for the Company:** Eledia.de | **Version:** v2.1

**Solr 9.10.0** | **Moodle 4.1-5.x**

Vollautomatisches Solr-Setup für Moodle Global Search mit optionalem Monitoring (Prometheus + Grafana).

> v2.1 - Production Ready | Automated Testing | Enhanced Security

---

## What's New in v2.1

- **Simplified Configuration**: `.env` now in root directory (no more `eledia-workplace/`)
- **Fixed Container Names**: Proper naming with `INSTANCE_NAME` (e.g., `solr-solr`)
- **CI/CD Pipeline**: GitHub Actions for automated testing
- **Better Security**: Enhanced `.gitignore`, no secrets in container environment
- **Improved Permissions**: Fixed chmod 655 → 755 bug
- **Log Rotation**: Structured logging with size limits (10MB max)
- **Standard Naming**: `Dockerfile.init` → `Dockerfile`

See [CHANGELOG.md](CHANGELOG.md) for full details.

---

## CI/CD Pipeline

### GitLab CI/CD (Empfohlen)

Automatisierte Tests bei jedem Push:

```bash
# .gitlab-ci.yml ist bereits konfiguriert
# Pushe einfach zu GitLab:
git push gitlab main
```

**Pipeline testet automatisch:**
- Syntax & Struktur-Validierung
- Container-Build
- Unit, Integration & Moodle Document Tests
- Security Tests & Secret Scanning

**Setup-Anleitungen:**
- [GitLab Quick Start (5 Min)](docs/GITLAB-QUICKSTART.md) - Für GitLab.com
- [Vollständige Anleitung](docs/GITLAB-CI-CD-SETUP.md) - Für Self-Hosted GitLab

**Pipeline Badge:**
```markdown
[![Pipeline](https://gitlab.com/USER/solr-moodle-docker/badges/main/pipeline.svg)](https://gitlab.com/USER/solr-moodle-docker/-/pipelines)
```

### GitHub Actions (Alternative)

Falls du GitHub verwendest: [.github/workflows/test.yml](.github/workflows/test.yml)

---

## Quick Installation

```bash
# 1. Setup (.env mit sicheren Passwörtern)
docker compose --profile setup up moodle_setup

# 2. Start
docker compose up -d

# 3. Fertig
```

Solr: `http://localhost:8983/solr`
Zugangsdaten: `.env` im Root-Verzeichnis

---

## Reverse Proxy

```bash
Nicht meine Baustelle :)
```

---

## Moodle Konfiguration

**Site Administration → /admin/settings.php?section=searchsolr**

| Setting  | Value                                     |
|----------|-------------------------------------------|
| Engine   | Solr                                      |
| Host     | localhost oder Proxy                      |
| Port     | 8983                                      |
| Path     | /solr                                     |
|Index name| moodle_core                               |
| Secure mode| Über Reverse Proxy ja! else only local  |
| Auth Username | moodle oder admin(Safe)              |
| Auth Password | (aus `.env`)                         |

**(der/die/das)Schema für die Moodle initialisieren per CLI anschubsen**
```bash
php admin/cli/search.php --setupschema
php admin/cli/search.php --reindex
```

---

## Multi-Core Setup

**`eledia-workplace/.env oder /.env` bearbeiten:**
```bash
# Single-Core (Standard)
SOLR_CORE_NAME=moodle_core

# Multi-Core
SOLR_CORES=core1,core2,core3
```

Alle Cores werden automatisch erstellt.

---

## Monitoring (Optional)

### Mit Prometheus + Grafana:
```bash
docker compose --profile monitoring up -d
```

### Nur Prometheus:
```bash
docker compose up -d solr prometheus
```

**Zugriff:**
- Prometheus: `http://localhost:9090`
- Grafana: `http://localhost:3000` (extern erreichbar, Login: admin/admin)

**Metriken:** 50 Solr-Metriken verfügbar (Core Performance, JVM, HTTP, Cache)
**Dokumentation:** `Hier kommt irgendwann eine wenn ich es selbst rausgefunden habe. Prometheus läuft :) `

---

## Befehle

```bash
docker compose ps                              # Status
docker compose logs -f solr                    # Logs
docker compose restart                         # Neustart
docker compose down                            # Stoppen (Daten bleiben erhalten)
docker compose down -v                         # Stoppen + Daten löschen
grep PASSWORD .env                             # Credentials anzeigen
```

---

## Passwörter ändern

```bash
# 1. .env bearbeiten
nano .env

# 2. Restart (mit init-Container für security.json Update)
docker compose down
docker compose up -d

# 3. Done (automatische Erkennung + Update)
```

Passwort-Änderungen werden automatisch erkannt und security.json wird neu generiert.

---

## Konfiguration

**`.env` (automatisch generiert):**
```bash
INSTANCE_NAME=solr                # Container-Prefix (Verbuggt ????)
SOLR_VERSION=9.10.0               # Solr Version
SOLR_HEAP=2g                      # RAM: 8GB→2g, 16GB→8g, 32GB→20g
SOLR_CORE_NAME=moodle_core        # Single-Core
SOLR_CORES=core1,core2            # Multi-Core (alternativ)
SOLR_BIND=127.0.0.1               # Localhost-only
```

**Heap Size Empfehlungen Laut Doku ob das Stimmt, Testen :) :**
- 8 GB RAM → `SOLR_HEAP=2g`
- 16 GB RAM → `SOLR_HEAP=8g`
- 32 GB RAM → `SOLR_HEAP=20g`

---

## Standard Benutzer

| User    | Rechte                          | Verwendung                    |
|---------|--------------------------------|-------------------------------|
| admin   | Voller Zugriff                 | Administration, Core-Management |
| moodle  | Read + Update                  | Moodle-Integration (Indexierung) |
| support | Read-only, Metrics             | Monitoring, Read-Only Zugriff |

**Alle Passwörter:** `.env` im Root-Verzeichnis

---

## Sicherheit

- **Binding:** `127.0.0.1` (localhost-only)
- **BasicAuth:** Solr-Standard
- **Passwort-Änderungen:** Automatische Erkennung
- **Extern Erreichbar:** Reverse Proxy erforderlich (nginx, Apache, Caddy)

**Beispiel Nginx Reverse Proxy (ungetestet):**
```nginx
location /solr/ {
    proxy_pass http://127.0.0.1:8983/solr/;
    proxy_set_header Authorization $http_authorization;
    proxy_pass_header Authorization;
}
```

---

## Testing

### Moodle Document Tests:
```bash
# Testet Indexierung + Queries (7 Dokumente bleiben im Index)
./scripts/test-moodle-documents.sh --keep-documents
```

### Connectivity Test:
```bash
# Test mit moodle User
curl -u moodle:PASSWORD http://localhost:8983/solr/moodle_core/admin/ping

# Erwartete Antwort: {"status":"OK"}
```

---

## Troubleshooting

### Known Issues

#### SELinux: Volume-Rechte nach `docker volume rm` / Neu-Erstellung

**Symptom:**
- Nachdem Volumes gelöscht und neu erstellt wurden (z. B. `docker compose down -v`), startet Solr nicht sauber oder zeigt **Permission denied** Fehler.

**Ursache:**
- Unter Fedora/RHEL (SELinux *enforcing*) bekommen neu erstellte Volumes nicht immer automatisch die passenden **SELinux-Labels** für Containerzugriff.

**Fix:**
```bash
# SELinux-Labels neu setzen
docker volume rm solr_data_solr prometheus_data_solr grafana_data_solr
docker compose --profile setup up moodle_setup
docker compose up -d
```

---

### Setup neu starten:
```bash
docker compose down -v
docker compose --profile setup up moodle_setup
docker compose up -d
```

### Logs prüfen:
```bash
docker compose logs solr-init    # Init-Container
docker compose logs solr         # Solr - Hauptservice
docker compose logs prometheus   # Prometheus - Monitoring
```

### Permissions prüfen:
```bash
# Solr Daten-Volume
docker run --rm -v solr_data_solr:/data alpine:3.20 ls -la /data/

# Sollte: drwxr-xr-x 8983:8983 zurückgeben
```

### Core manuell erstellen:
```bash
docker compose exec solr solr create -c <core_name>
```

---

## Ansible Integration (Nicht getestet)

```yaml
- name: Deploy Solr for Moodle
  hosts: solr_servers
  tasks:
    - name: Sync Files
      synchronize:
        src: solr-docker-nativ/
        dest: /opt/solr/
        rsync_opts:
          - "--exclude=.git"
          - "--exclude=backup"

    - name: Generate .env
      docker_compose:
        project_src: /opt/solr
        files: docker-compose.yml
        profiles: setup

    - name: Start Solr
      docker_compose:
        project_src: /opt/solr
        files: docker-compose.yml
        state: present

    - name: Start Monitoring (optional)
      docker_compose:
        project_src: /opt/solr
        files: docker-compose.yml
        profiles: monitoring
        state: present
```

---

## Architecture

### Service Flow:
```
1. moodle_setup (profile: setup)
   └─> Generiert .env mit zufälligen Passwörtern im Root-Verzeichnis

2. solr-init (Dockerfile)
   └─> Lädt .env, erstellt security.json, Cores, prometheus.yml
   └─> Setzt Permissions (8983:8983)

3. solr (Hauptservice)
   └─> Wartet auf init completion, startet mit BasicAuth

4. prometheus + grafana (profile: monitoring, optional)
   └─> Metrics-Scraping von Solr
```

### Volumes:
- `solr_data_<instance>` - Solr Index + Config + security.json
- `prometheus_data_<instance>` - Prometheus TSDB
- `prometheus_config_<instance>` - Prometheus Config (optional kann auch Standalone ohne Grafana also nur für Metriken diese sind getestet und funktionieren.)
- `grafana_data_<instance>` - Grafana Dashboards (optional hat auch Fehler wie Dashbaord wird nicht Automatisch erstellt, aber Grafana läuft :) )

### Networks:
- `<instance>_network` - Bridge Network

---

## Support & Links

**Developer:** BSC Bernd Schreistetter
**Company:** Eledia.de
**Version:** v2.1
**Status:** Production Ready | CI/CD Tested | Fedora 43

**Links:**
- [Apache Solr Documentation](https://solr.apache.org/guide/)
- [Moodle Global Search](https://docs.moodle.org/en/Global_search)
- [Eledia GmbH](https://eledia.de)

---
