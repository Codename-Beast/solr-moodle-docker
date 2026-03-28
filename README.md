# Solr für Moodle

[![CI](https://github.com/Codename-Beast/solr-moodle-docker/actions/workflows/solr-testing.yml/badge.svg?branch=feature%2Fv2.3.1)](https://github.com/Codename-Beast/solr-moodle-docker/actions/workflows/solr-testing.yml)
![Version](https://img.shields.io/badge/version-2.3.1-blue)
![Solr](https://img.shields.io/badge/solr-9.10.1-orange)
![Moodle](https://img.shields.io/badge/moodle-4.1--5.x-purple)
![Tested](https://img.shields.io/badge/getestet-Debian%2012%2F13-green)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

**Autor:** Bernd Schreistetter | **Organisation:** Eledia GmbH | **Version:** v2.3.1

**Solr 9.10.1** | **Moodle 4.1–5.x** | **Debian 12/13**

Vollautomatisches Solr-Setup für Moodle Global Search mit optionalem Monitoring (Prometheus + Grafana).

> v2.3.1 | CVE-Fix Solr 9.10.1, Multi-Core, Security Hardening

---
See [CHANGELOG.md](CHANGELOG.md) for full details.

---

## Quick Installation

```bash
# 1. Setup (.env mit sicheren Passwörtern)
docker compose --profile setup up moodle_setup

# Optional: Mit custom Core-Namen
SOLR_CORE_NAME=my_custom_core docker compose --profile setup up moodle_setup

# 2. Start
docker compose up -d

# 3. Fertig
```

> **Hinweis:** Nach Änderungen an `init/powerinit.sh` oder `init/security.json.template` muss das Init-Image neu gebaut werden:
> ```bash
> docker compose build --no-cache solr-init
> ```

Solr: `http://localhost:8983/solr`
Zugangsdaten: `.env` im Root-Verzeichnis

---

## Reverse Proxy

```bash
Comming Soon
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
| Auth Username | moodle oder admin                    |
| Auth Password | (aus `.env`)                         |

**(der/die/das)Schema für die Moodle initialisieren per CLI anschubsen**
```bash
php admin/cli/search.php --setupschema
php admin/cli/search.php --reindex
```

---

## Multi-Core Setup

**`.env` bearbeiten:**
```bash
# Single-Core (Standard)
SOLR_CORE_NAME=moodle_core

# Multi-Core
SOLR_CORES=core1,core2,core3
```

Cores werden automatisch erstellt/gelöscht beim Restart.

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

# 2. Restart
docker compose down
docker compose up -d
```

Passwörter werden automatisch generiert wenn leer oder "CHANGE_ME".

---

## Konfiguration

**`.env` (automatisch generiert):**
```bash
INSTANCE_NAME=solr                # Container-Prefix
SOLR_VERSION=9.10.1               # Solr Version
SOLR_HEAP=2g                      # RAM: 8GB→2g, 16GB→8g, 32GB→20g
SOLR_CORE_NAME=moodle_core        # Single-Core
SOLR_CORES=core1,core2            # Multi-Core (alternativ)
SOLR_BIND=127.0.0.1               # Localhost-only
```

**Heap Size Empfehlungen:**
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
# Testet Indexierung + Queries (7 Dokumente)
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

Keine Bekannt

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
- `prometheus_config_<instance>` - Prometheus Config
- `grafana_data_<instance>` - Grafana Dashboards

### Networks:
- `<instance>_network` - Bridge Network

---

## CI/CD & Testing

Automatisierte Tests für GitHub Actions und GitLab CI sind eingerichtet.

**Dokumentation:** [docs/CI-CD.md](docs/CI-CD.md)

---

## Support & Links

**Developer:** BSC Bernd Schreistetter
**Company:** Eledia.de
**Version:** v2.3.1
**Status:** Docker Tested | CI/CD Tested (Github)

**Links:**
- [Apache Solr Documentation](https://solr.apache.org/guide/)
- [Moodle Global Search](https://docs.moodle.org/en/Global_search)
- [Eledia GmbH](https://eledia.de)

---
