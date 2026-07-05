# Solr für Moodle — Multi-Tenant Docker Stack

![CI](https://img.shields.io/badge/ci-GitHub%20%2B%20GitLab-brightgreen)
![Version](https://img.shields.io/badge/version-3.4.11-blue)
![Solr](https://img.shields.io/badge/solr-9.10.1-orange)
![Moodle](https://img.shields.io/badge/moodle-4.1--5.x-purple)
![Tested](https://img.shields.io/badge/getestet-Debian%2012%2F13-green)

Docker-Stack für Moodle Global Search mit Solr 9.10.1, Tika und Tenant-Isolation.
Jeder Tenant bekommt eigene Zugangsdaten und Zugriff auf die eigenen Cores oder Collections.

Solr bleibt standardmäßig auf `127.0.0.1` gebunden. Externe Zugriffe laufen über Reverse Proxy.

---

## Inhalt

| Bereich | Links |
|---|---|
| Start | [Voraussetzungen](#voraussetzungen) · [Schnellstart](#schnellstart) |
| Betrieb | [Architektur](#architektur) · [Reverse Proxy](#reverse-proxy) · [Moodle einstellen](#moodle-einstellen) |
| Tenants | [Tenant-Verwaltung](#tenant-verwaltung) · [SolrCloud](#solrcloud) |
| Qualität | [Sicherheit](#sicherheit) · [Tests](#tests) |
| Doku | [Weitere Dokumentation](#weitere-dokumentation) |

---

## Voraussetzungen

| Komponente | Minimum |
|---|---|
| Docker | 24+ inkl. Compose-Plugin |
| Solr | 9.10.1 |

---

## Schnellstart

```bash
git clone <repo-url>
cd solr-moodle-docker
./setup.sh
```

Das Setup fragt die wichtigsten Werte ab, erzeugt Passwörter, baut die Images und startet den Stack.

Manuell:

```bash
cp .env.example .env
$EDITOR .env
docker compose up -d --build
```

Platzhalter wie `CHANGE_ME` werden beim Start abgewiesen.

Healthcheck:

```bash
docker compose ps
docker exec <containername> /opt/solr/scripts/solr-tenant.sh healthcheck
```

Der Compose-Healthcheck prüft Solr, Auth und Bootstrap-Zustand. Tenant-Drift wird separat mit `drift-detect` geprüft.

---

## Architektur

![Installation und Bootstrap](docs/architecture-install.svg)

![Runtime Architektur](docs/architecture-runtime.svg)

Der Stack trennt Bootstrap und Runtime:

| Container | Aufgabe |
|---|---|
| `eLeDia-solr-init` | schreibt `security.json`, Configsets und Bootstrap-Metadaten |
| `solr` | Runtime-Solr für Cores oder Collections |

Der Runtime-Container startet erst nach erfolgreichem Init.

```text
Moodle -> Reverse Proxy -> Solr Core/Collection
```

Details: [docs/architecture.md](docs/architecture.md)

---

## Reverse Proxy

Solr bleibt lokal gebunden (`SOLR_BIND=127.0.0.1`). Extern läuft der Zugriff über HTTPS.

| Proxy | Status | Konfiguration |
|---|---|---|
| Caddy | empfohlen | `docker compose -f docker-compose.proxy.yml --profile caddy up -d` |
| Apache | unterstützt | `./apache/generate-apache-config.sh` |
| Nginx | unterstützt | `docker compose -f docker-compose.proxy.yml --profile nginx up -d` oder `./nginx/generate-nginx-config.sh` |

Proxy als Container:

```bash
PROXY_HOSTNAME=kundendomain.de PROXY_SOLR_HOSTNAME=solr.kundendomain.de \
  docker compose -f docker-compose.proxy.yml --profile caddy up -d

PROXY_HOSTNAME=kundendomain.de PROXY_SOLR_HOSTNAME=solr.kundendomain.de \
  docker compose -f docker-compose.proxy.yml --profile nginx up -d
```

Damit ist Solr erreichbar über:

```text
https://kundendomain.de/solr
https://solr.kundendomain.de    # redirectet nach /solr/
```

Der Proxy-Container hängt automatisch am externen Netzwerk `${INSTANCE_NAME:-solr}-network`.
Default-Upstream: `${INSTANCE_NAME:-solr}-solr:${SOLR_PORT:-8983}`.

Abweichender Container oder Port:

```bash
SOLR_UPSTREAM=my-solr-container:18983 \
PROXY_HOSTNAME=kundendomain.de \
PROXY_SOLR_HOSTNAME=solr.kundendomain.de \
  docker compose -f docker-compose.proxy.yml --profile caddy up -d
```

Mehr: [proxy_guid.md](proxy_guid.md)

---

## Moodle einstellen

In Moodle unter `Website-Administration -> Plugins -> Suche -> Solr` bzw. `Global Search`:

| Moodle-Feld | Wert |
|---|---|
| Hostname | öffentlicher Proxy-Hostname oder interner Host |
| Port | `443` bei HTTPS über Proxy, sonst interner Solr-Port |
| Index name / Core / Collection | Core oder Collection des Tenants |
| Username | Tenant-User aus `tenants.env`, z. B. `solr_schule_a` |
| Password | Tenant-Passwort aus `tenants.env` |
| Secure / HTTPS | aktivieren, wenn Moodle Solr über `https://` erreicht |

Merksatz: Die Moodle-Secure-Option beschreibt die Verbindung von Moodle zum sichtbaren Solr-Endpunkt.
`https://` bedeutet Secure an, `http://` bedeutet Secure aus.

---

## Tenant-Verwaltung

Jede Moodle-Instanz ist ein Tenant: eigener User, eigenes Passwort, eigene Cores oder Collections.

```bash
# Tenant anlegen
docker exec <containername> /opt/solr/scripts/solr-tenant.sh create schule_a --cores moodle_prod

# Tenants anzeigen
docker exec <containername> /opt/solr/scripts/solr-tenant.sh list

# Passwort rotieren
docker exec <containername> /opt/solr/scripts/solr-tenant.sh passwd schule_a

# Explizites Passwort setzen
docker exec <containername> /opt/solr/scripts/solr-tenant.sh passwd schule_a --password '<neues-passwort>'

# Source of Truth anwenden
docker exec <containername> /opt/solr/scripts/solr-tenant.sh sync-sot

# Permissions neu aufbauen
docker exec <containername> /opt/solr/scripts/solr-tenant.sh rebuild-permissions

# Drift prüfen und beheben
docker exec <containername> /opt/solr/scripts/solr-tenant.sh drift-detect
docker exec <containername> /opt/solr/scripts/solr-tenant.sh drift-remediate

# Runtime-Wahrheit aus Solr API/ZooKeeper lesen
docker exec <containername> /opt/solr/scripts/solr-tenant.sh runtime-truth

# Hostvars aus tenants.env exportieren
docker exec <containername> /opt/solr/scripts/solr-tenant.sh export
```

`runtime-truth` liest den Live-Zustand aus der Solr Security API und in SolrCloud zusätzlich aus Collections API/ZooKeeper.

---

## SolrCloud

SolrCloud ist der Default:

```bash
SOLR_MODE=solrcloud
ZK_MAX_CNXNS=60
```

| Thema | Standalone | SolrCloud |
|---|---|---|
| Objekt | Core | Collection |
| Isolation | Security + Proxy-Regeln | Collections + Security API |
| Persistenz | Volume | Volume + ZooKeeper |

Die Tenant-Befehle bleiben in beiden Modi gleich.

---

## Konfiguration

Die wichtigsten Werte aus `.env.example`:

| Variable | Default | Bedeutung |
|---|---|---|
| `STACK_VERSION` | `v3.4.11` | Init-Image-Tag |
| `INSTANCE_NAME` | `solr` | Präfix für Container, Volume und Network |
| `SOLR_VERSION` | `9.10.1` | Solr-Version |
| `SOLR_PORT` | `8983` | Solr-Port auf dem Host |
| `SOLR_BIND` | `127.0.0.1` | Bind-Adresse, nicht öffentlich öffnen |
| `SOLR_HEAP` | `2g` | JVM Heap |
| `SOLR_MODE` | `solrcloud` | `solrcloud` oder `standalone` |
| `ELEDIA_LOG_ROOT` | `/var/log/eledia/solr` | Host-Root für Logs |
| `TENANTS_ENV` | `/opt/solr/tenants.env` | Tenant Source of Truth im Container |

---

## Sicherheit

- Solr bleibt lokal gebunden.
- Externe Zugriffe laufen über TLS-Proxy.
- Tenant-User bekommen nur Rechte für ihre Cores oder Collections.
- Pflichtpasswörter müssen gesetzt sein.
- Basic Auth wird an Solr weitergereicht.

---

## Verzeichnisstruktur

```text
solr-moodle-docker/
├── docker-compose.yml          # Stack
├── docker-compose.proxy.yml    # Caddy/Nginx als Proxy-Container
├── .env.example                # Konfigurationsvorlage
├── Dockerfile                  # eLeDia-solr-init
├── Dockerfile.solr             # Solr Runtime mit Tika
├── init/                       # Bootstrap
├── eLeDia-config/              # Moodle-Schema und Solr config
├── scripts/                    # Tenant-CLI und Tests
├── apache/                     # Apache-Generator
├── nginx/                      # Nginx-Generator und Container-Template
├── caddy/                      # Caddyfile für Container-Proxy
└── docs/                       # Betriebsdokumentation
```

---

## Tests

| Zweck | Befehl |
|---|---|
| Unit-Tests | `./scripts/run-tests.sh --unit-only` |
| Stack mit Tenant-Checks | `./scripts/run-tests.sh --tenant` |
| Tenant-CLI | `./scripts/run-tests.sh --tenant-commands` |
| Moodle/Indexierung | `./scripts/test-moodle-documents.sh` |
| SolrCloud Scale | `./scripts/run-tests.sh --cloud --tenant --tenant-scale --no-performance` |

Die CI prüft Lint, Security Scan, Standalone und SolrCloud inklusive Tenant-Isolation.

---

## Weitere Dokumentation

| Dokument | Inhalt |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Komponenten, Bootstrap, Runtime |
| [proxy_guid.md](proxy_guid.md) | Reverse Proxy mit Caddy, Apache und Nginx |
| [CHANGELOG.md](CHANGELOG.md) | Änderungshistorie |

---

**eLeDia GmbH** Developer : Bernd Schreistetter
