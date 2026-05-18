# Solr fuer Moodle — Multi-Tenant

[![CI](https://github.com/Codename-Beast/solr-moodle-docker/actions/workflows/solr-testing.yml/badge.svg?branch=feature%2Fmulti-tenant)](https://github.com/Codename-Beast/solr-moodle-docker/actions/workflows/solr-testing.yml)
![Version](https://img.shields.io/badge/version-3.0.0-blue)
![Solr](https://img.shields.io/badge/solr-9.10.1-orange)
![Moodle](https://img.shields.io/badge/moodle-4.1--5.x-purple)
![Tested](https://img.shields.io/badge/getestet-Debian%2012%2F13-green)

**Autor:** Bernd Schreistetter | **Organisation:** Eledia GmbH | **Version:** v3.0.0

**Solr 9.10.1** | **Moodle 4.1–5.x** | **Debian 12/13**

Docker-Stack fuer Solr + Moodle Global Search. Unterstuetzt mehrere Moodle-Instanzen (Multi-Tenant) auf einem Solr-Server — jeder Tenant bekommt eigene Cores und einen dedizierten Benutzer mit isoliertem Zugriff.

> v3.0.0 | Multi-Tenant via `solr-tenant.sh` | SolrCloud-Modus optional | Tika-Datei-Indexierung | Caddy-Proxy-Unterstuetzung

---

See [CHANGELOG.md](CHANGELOG.md) for full details.

---

## Architektur

```
                    ┌──────────────────────────────────────┐
                    │     Caddy / Apache / Nginx           │
                    │     (TLS, IP-Whitelist, URL-Routing)  │
                    └───────────────┬──────────────────────┘
                                    │
                    ┌───────────────▼──────────────────────┐
                    │           Solr 9.x                   │
                    │  ┌─────────────┐  ┌─────────────┐   │
                    │  │ moodle_a_1  │  │ moodle_b_1  │   │
                    │  │ moodle_a_2  │  │ moodle_b_2  │   │
                    │  └─────────────┘  └─────────────┘   │
                    │   Tenant A           Tenant B        │
                    └──────────────────────────────────────┘

Jeder Tenant hat:
  - Eigene Solr-Cores (Indexe)
  - Eigenen Benutzer (nur Zugriff auf eigene Cores)
  - Optionale URL-Isolation via Caddy-Subdomain
```

---

## Schnellstart

```bash
# 1. Repo klonen
git clone https://github.com/Codename-Beast/solr-moodle-docker
cd solr-moodle-docker

# 2. .env anlegen (kopieren und Passwoerter setzen)
cp .env.example .env
nano .env

# 3. Init-Image bauen und Stack starten
docker compose build --no-cache solr-init
docker compose up -d

# 4. Ersten Tenant anlegen
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh create schule_a \
  --cores moodle_prod_a,moodle_test_a

# Passwort wird angezeigt — fuer Moodle notieren
```

Solr Admin: `http://localhost:8983/solr`
Zugangsdaten: `.env` (Admin + Support) und `tenants.env` (Tenant-Passwoerter)

---

## Multi-Tenant Verwaltung

### Tenant anlegen

```bash
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh create schule_a \
  --cores moodle_prod_a,moodle_test_a
```

Gibt Zugangsdaten fuer Moodle aus — einmalig anzeigen, sofort in Moodle eintragen.

### Uebersicht

```bash
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh list
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh info schule_a
```

### Passwort erneuern

```bash
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh passwd schule_a
```

### Core hinzufuegen / entfernen

```bash
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh core-add schule_a --core moodle_staging_a
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh core-remove schule_a --core moodle_staging_a
```

### Tenant deaktivieren / reaktivieren

```bash
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh delete schule_a   # sperrt User, Daten bleiben
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh enable schule_a   # neues Passwort, reaktiviert
```

### Alle Subcommands

| Befehl | Beschreibung |
|--------|-------------|
| `create <name> --cores <c1>[,<c2>]` | Cores anlegen, User erstellen, Passwort ausgeben |
| `delete <name>` | User sperren, Status `ACTIVE=false` |
| `enable <name>` | User reaktivieren, neues Passwort |
| `list` | Alle Tenants tabellarisch |
| `info <name>` | Details: Cores, User, Status |
| `passwd <name>` | Neues Passwort generieren |
| `core-add <name> --core <core>` | Core hinzufuegen |
| `core-remove <name> --core <core>` | Core entfernen (Daten bleiben) |
| `apply` | Alle Tenants aus `tenants.env` idempotent neu anwenden |
| `export` | YAML-Ausgabe aller Tenants (ohne Passwoerter) fuer Ansible |
| `caddy-config --domain <d>` | Caddyfile-Snippet fuer URL-Isolation generieren |

Alle Subcommands unterstuetzen `--dry-run`.

---

## tenants.env

`tenants.env` ist die Single Source of Truth fuer alle Tenants.
Wird automatisch von `solr-tenant.sh` verwaltet — nicht manuell bearbeiten.

```bash
TENANT_schule_a_CORES=moodle_prod_a,moodle_test_a
TENANT_schule_a_USER=solr_schule_a
TENANT_schule_a_PASS=<auto_generiert_32_zeichen>
TENANT_schule_a_ACTIVE=true

TENANT_schule_b_CORES=moodle_prod_b
TENANT_schule_b_USER=solr_schule_b
TENANT_schule_b_PASS=<auto_generiert_32_zeichen>
TENANT_schule_b_ACTIVE=true
```

Bei jedem Container-Start regeneriert `powerinit.sh` die `security.json` komplett
aus `.env` (Admin/Support) und `tenants.env` (alle Tenants) — kein State-Drift moeglich.

---

## Moodle Konfiguration

**Site Administration → /admin/settings.php?section=searchsolr**

| Einstellung | Wert |
|-------------|------|
| Engine | Solr |
| Host | Proxy-Domain oder `localhost` |
| Port | 8983 (oder 443 via Proxy) |
| Path | `/solr` |
| Index name | z.B. `moodle_prod_a` |
| Auth Username | z.B. `solr_schule_a` |
| Auth Password | Passwort aus `tenants.env` / `solr-tenant.sh create` |

Schema initialisieren und Index anstossen:
```bash
php admin/cli/search.php --setupschema
php admin/cli/search.php --reindex
```

---

## Reverse Proxy

Solr laeuft auf `127.0.0.1:8983` — nie direkt oeffentlich erreichbar.

### Caddy (empfohlen — automatisches TLS, URL-Isolation)

```caddy
# Generieren mit:
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh caddy-config --domain solr.example.com
```

Erzeugt Caddyfile mit pro-Tenant-Subdomains — jeder Tenant sieht nur seine eigenen Cores:

```caddy
# Admin-Endpunkt (interner Zugriff)
solr.example.com {
    reverse_proxy localhost:8983
}

# Tenant: schule_a
schule-a.solr.example.com {
    @allowed path /solr/moodle_prod_a /solr/moodle_prod_a/* /solr/moodle_test_a /solr/moodle_test_a/*
    handle @allowed {
        reverse_proxy localhost:8983
    }
    handle {
        respond "Forbidden" 403
    }
}
```

### Apache

Vorgefertigte Templates fuer Apache VHosts: [`apache/`](apache/README.md)

```bash
./apache/generate-apache-config.sh \
  --instance schule_a \
  --hostname solr-schule-a.example.com \
  --port 8983
```

### Nginx

```nginx
location /solr/ {
    proxy_pass http://127.0.0.1:8983/solr/;
    proxy_set_header Authorization $http_authorization;
    proxy_pass_header Authorization;
}
```

---

## Konfiguration (.env)

```bash
INSTANCE_NAME=solr                # Container-Prefix (z.B. "solr" → Container "solr-solr")
SOLR_VERSION=9.10.1
SOLR_HEAP=2g                      # RAM: 8GB→2g, 16GB→8g, 32GB→20g
SOLR_BIND=127.0.0.1               # SICHERHEIT: nie 0.0.0.0 setzen
SOLR_PORT=8983

# Betriebsmodus
SOLR_MODE=                        # leer = Standalone (Standard)
                                  # solrcloud = eingebetteter ZooKeeper (wahre Core-Isolation)

# Benutzer
SOLR_ADMIN_USER=admin
SOLR_ADMIN_PASSWORD=...           # 32 Zeichen, alphanumerisch
SOLR_SUPPORT_USER=support
SOLR_SUPPORT_PASSWORD=...

# Ressourcen
SOLR_CPU_LIMIT=2
SOLR_MEMORY_LIMIT=4G
SOLR_CPU_RESERVATION=0.5
SOLR_MEMORY_RESERVATION=2G
```

**Heap Size:**
- 8 GB RAM → `SOLR_HEAP=2g`
- 16 GB RAM → `SOLR_HEAP=8g`
- 32 GB RAM → `SOLR_HEAP=20g`

---

## SolrCloud-Modus (optional)

Setzt `SOLR_MODE=solrcloud` in `.env` — aktiviert eingebetteten ZooKeeper.

```bash
# .env
SOLR_MODE=solrcloud
```

Vorteile: echte Collection-Level-Isolation (403 ohne Proxy-Hilfe).
Nachteile: hoehere Ressourcen, komplexeres Startup-Verhalten.

Standalone-Modus reicht fuer die meisten Deployments — Isolation erfolgt dort ueber den Proxy.

---

## Benutzer

| User | Rechte | Verwendung |
|------|--------|-----------|
| `admin` | Vollzugriff | Administration, Core-Management |
| `support` | Lesend, Metriken | Monitoring, Read-Only |
| `solr_<name>` | Nur eigene Cores | Moodle-Integration (ein User pro Tenant) |

Admin und Support in `.env`, Tenants in `tenants.env`.

---

## Befehle

```bash
docker compose ps                              # Status
docker compose logs -f solr                    # Logs
docker compose restart                         # Neustart (Daten bleiben, security.json wird neu gebaut)
docker compose down                            # Stoppen (Daten bleiben)
docker compose down -v                         # Stoppen + Daten weg
```

---

## Troubleshooting

### Logs pruefen

```bash
docker compose logs solr-init    # Init-Container (security.json, Cores)
docker compose logs solr         # Solr-Prozess
```

### Init neu erzwingen

```bash
docker compose build --no-cache solr-init
docker compose down
docker compose up -d
```

### Tenant-Zugriff testen

```bash
PASS=$(grep "TENANT_schule_a_PASS" tenants.env | cut -d= -f2)
curl -sf -u "solr_schule_a:$PASS" http://localhost:8983/solr/moodle_prod_a/select?q=*:*
# → 200 OK

curl -sf -u "solr_schule_a:$PASS" http://localhost:8983/solr/moodle_prod_b/select
# → 403 Forbidden (im SolrCloud-Modus) bzw. per Proxy-Regel gesperrt
```

### Alle Tenants neu anwenden (nach manuellen Aenderungen)

```bash
docker exec solr-solr /opt/solr/scripts/solr-tenant.sh apply
```

### Permissions auf Volume pruefen

```bash
docker run --rm -v solr_data_solr:/data alpine:3.20 ls -la /data/
# Sollte 8983:8983 sein
```

---

## Monitoring

Metriken: `http://localhost:8983/solr/admin/metrics` (BasicAuth, Support-User)

Prometheus- und Loki-Integration: [`docs/monitoring.md`](docs/monitoring.md)

---

## Backup

```bash
docker exec solr-solr /opt/solr/scripts/solr-backup.sh
```

Sichert alle Cores aus `tenants.env` automatisch.

---

## Ansible-Integration

Fuer produktiven Einsatz (idempotent, mit Smoke-Tests, Proxy, Multi-Tenant):
**[ansible-role-solr](https://github.com/Codename-Beast/ansible-role-solr)** (v1.9.5+)

```yaml
# inventory/host_vars/moodle-server.yml
solr_instance_name: "eledia-solr"
solr_port:          8983
solr_heap:          "2g"

solr_tenants:
  - name: schule_a
    cores:
      - moodle_prod_a
      - moodle_test_a
    state: present
  - name: schule_b
    cores:
      - moodle_prod_b
    state: present
```

```bash
ansible-playbook -i inventory examples/install_solr.yml
ansible-playbook -i inventory examples/install_solr.yml --tags solr_tenants
```

---

## Support & Links

**Developer:** BSC Bernd Schreistetter
**Company:** Eledia.de
**Version:** v3.0.0

- [Apache Solr Documentation](https://solr.apache.org/guide/)
- [Moodle Global Search](https://docs.moodle.org/en/Global_search)
- [Eledia GmbH](https://eledia.de)

---
