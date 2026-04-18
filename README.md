# Solr fuer Moodle

[![CI](https://github.com/Codename-Beast/solr-moodle-docker/actions/workflows/solr-testing.yml/badge.svg?branch=feature%2Fv2.3.2)](https://github.com/Codename-Beast/solr-moodle-docker/actions/workflows/solr-testing.yml)
![Version](https://img.shields.io/badge/version-2.3.2-blue)
![Solr](https://img.shields.io/badge/solr-9.10.1-orange)
![Moodle](https://img.shields.io/badge/moodle-4.1--5.x-purple)
![Tested](https://img.shields.io/badge/getestet-Debian%2012%2F13-green)

**Autor:** Bernd Schreistetter | **Organisation:** Eledia GmbH | **Version:** v2.3.2

**Solr 9.10.1** | **Moodle 4.1–5.x** | **Debian 12/13**

Docker-Stack fuer Solr + Moodle Global Search. Setup generiert `.env` mit sicheren Passwoertern, Init-Container erledigt den Rest (Cores, security.json, Permissions).

> v2.3.2 | config-read Fix fuer Moodle, Resource Limits aus .env, chmod 600

---
See [CHANGELOG.md](CHANGELOG.md) for full details.

---

## Quick Installation

```bash
# 1. Setup (.env mit sicheren Passwoertern)
docker compose --profile setup up moodle_setup

# Optional: Mit custom Core-Namen
SOLR_CORE_NAME=my_custom_core docker compose --profile setup up moodle_setup

# 2. Start
docker compose up -d

# 3. Fertig
```

> Nach Aenderungen an `init/powerinit.sh` oder `init/security.json.template` muss das Init-Image neu gebaut werden:
> ```bash
> docker compose build --no-cache solr-init
> ```

Solr: `http://localhost:8983/solr`
Zugangsdaten: `.env` im Root-Verzeichnis

---

## Reverse Proxy

Solr laeuft auf `127.0.0.1:8983` — extern nur ueber Reverse Proxy erreichbar.

**Nginx:**
```nginx
location /solr/ {
    proxy_pass http://127.0.0.1:8983/solr/;
    proxy_set_header Authorization $http_authorization;
    proxy_pass_header Authorization;
}
```

**Apache:**
```apache
ProxyPass "/solr" "http://127.0.0.1:8983/solr"
ProxyPassReverse "/solr" "http://127.0.0.1:8983/solr"
```

**Caddy:**
```
reverse_proxy /solr/* localhost:8983
```

Fuer produktiven Einsatz mit TLS, IP-Whitelist und Kollisionserkennung: [ansible-role-solr](https://github.com/Codename-Beast/ansible-role-solr).

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
| Secure mode| Ueber Reverse Proxy ja! else only local  |
| Auth Username | moodle oder admin                    |
| Auth Password | (aus `.env`)                         |

Schema initialisieren und Index anstossen:
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

Cores werden automatisch erstellt/geloescht beim Restart.

---

## Monitoring

Solr stellt Metriken unter `/solr/admin/metrics` bereit (BasicAuth, Support-User).

Prometheus- und Loki-Integration: [`docs/monitoring.md`](docs/monitoring.md)

---

## Befehle

```bash
docker compose ps                              # Status
docker compose logs -f solr                    # Logs
docker compose restart                         # Neustart
docker compose down                            # Stoppen (Daten bleiben)
docker compose down -v                         # Stoppen + Daten weg
grep PASSWORD .env                             # Credentials
```

---

## Passwoerter aendern

```bash
# 1. .env bearbeiten
nano .env

# 2. Restart
docker compose down
docker compose up -d
```

Passwoerter werden automatisch generiert wenn leer oder "CHANGE_ME".

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

**Heap Size:**
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

Alle Passwoerter stehen in `.env`.

---

## Troubleshooting

### Setup neu starten:
```bash
docker compose down -v
docker compose --profile setup up moodle_setup
docker compose up -d
```

### Logs:
```bash
docker compose logs solr-init    # Init-Container
docker compose logs solr         # Solr
```

Solr native log files (within container at `/var/solr/logs/`):
```bash
docker exec <instance>-solr tail -f /var/solr/logs/solr.log
```

To mount native logs to the host, add to `docker-compose.override.yml`:
```yaml
services:
  solr:
    volumes:
      - ./logs/solr:/var/solr/logs:z
```
Then `mkdir -p logs/solr && chmod 777 logs/solr` before starting.

### Permissions:
```bash
docker run --rm -v solr_data_solr:/data alpine:3.20 ls -la /data/
# Sollte 8983:8983 sein
```

### Core manuell erstellen:
```bash
docker compose exec solr solr create -c <core_name>
```

---

## Ansible Integration

Fuer produktiven Einsatz (idempotent, mit Smoke-Tests, Proxy, Moodle-Integration):
**[ansible-role-solr](https://github.com/Codename-Beast/ansible-role-solr)**

```yaml
# inventory/host_vars/moodle-server.yml
solr_instance_name: "eledia-solr"
solr_port:          8983
solr_heap:          "2g"
solr_core_name:     "moodle_core"
```

```bash
ansible-playbook -i inventory examples/install_solr.yml
# Credentials werden am Ende ausgegeben — in host_vars speichern
```

Die Rolle clont dieses Repo automatisch, schreibt `.env` und startet den Stack.

---

## Support & Links

**Developer:** BSC Bernd Schreistetter
**Company:** Eledia.de
**Version:** v2.3.2

- [Apache Solr Documentation](https://solr.apache.org/guide/)
- [Moodle Global Search](https://docs.moodle.org/en/Global_search)
- [Eledia GmbH](https://eledia.de)

---
