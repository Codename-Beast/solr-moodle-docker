# Proxy Guide für Solr

Kurzguide für Reverse-Proxy-Setups vor dem Solr/Moodle-Stack.

Caddy, Apache und Nginx sind unterstützt. Caddy und Nginx können direkt als Proxy-Container laufen.

---

## Ziel

Der Proxy soll:

- HTTPS nach außen bereitstellen
- intern sauber an Solr weiterleiten
- `Host` und `X-Forwarded-*` korrekt setzen
- Basic Auth an Solr durchreichen
- keine unnötigen Pfad-Rewrites machen

Solr selbst bleibt standardmäßig auf `127.0.0.1` gebunden.

---

## Unterstützte Wege

| Proxy | Status | Weg |
|---|---|---|
| Caddy | empfohlen | `docker-compose.proxy.yml` oder `solr-tenant.sh caddy-config` |
| Apache | unterstützt | `apache/generate-apache-config.sh` |
| Nginx | unterstützt | `docker-compose.proxy.yml` oder `nginx/generate-nginx-config.sh` |

---

## Upstream wählen

| Proxy läuft ... | Solr-Upstream |
|---|---|
| auf dem Host | `http://127.0.0.1:${SOLR_PORT}/solr/` |
| als Container im Solr-Netzwerk | `http://${INSTANCE_NAME}-solr:${SOLR_PORT}/solr/` |
| als Container mit Alias | `http://solr:${SOLR_PORT}/solr/` |

Ein Proxy-Container sieht Solr nur, wenn er am selben Docker-Netzwerk hängt.
`docker-compose.proxy.yml` erledigt das automatisch über `${INSTANCE_NAME:-solr}-network`.

---

## Proxy-Container starten

Caddy:

```bash
PROXY_HOSTNAME=kundendomain.de PROXY_SOLR_HOSTNAME=solr.kundendomain.de \
  docker compose -f docker-compose.proxy.yml --profile caddy up -d
```

Nginx:

```bash
PROXY_HOSTNAME=kundendomain.de PROXY_SOLR_HOSTNAME=solr.kundendomain.de \
  docker compose -f docker-compose.proxy.yml --profile nginx up -d
```

Danach ist Solr erreichbar über:

```text
https://kundendomain.de/solr
https://solr.kundendomain.de    # redirectet nach /solr/
```

Default-Upstream im Container:

```text
${INSTANCE_NAME:-solr}-solr:${SOLR_PORT:-8983}
```

Abweichender Upstream:

```bash
SOLR_UPSTREAM=my-solr-container:18983 \
PROXY_HOSTNAME=kundendomain.de \
PROXY_SOLR_HOSTNAME=solr.kundendomain.de \
  docker compose -f docker-compose.proxy.yml --profile caddy up -d
```

---

## Caddy

Container-Modus ist der einfache Weg. Caddy verwaltet TLS automatisch, wenn DNS und Ports passen.

Host-Modus kann über die Tenant-CLI generiert werden:

```bash
docker exec <containername> /opt/solr/scripts/solr-tenant.sh caddy-config --domain solr.example.org
```

Wichtig:

- keine zusätzlichen `/solr`-Rewrites
- Upstream passend zum Betriebsort wählen
- extern HTTPS, intern HTTP ist korrekt

---

## Apache

Apache ist vor allem für klassische Host-Setups gedacht.

```bash
./apache/generate-apache-config.sh
```

Wichtig:

- `ProxyPreserveHost On`
- `X-Forwarded-Proto https`
- `ProxyPass /solr/ http://127.0.0.1:${SOLR_PORT}/solr/`

Wenn Apache als Container läuft, muss der Upstream auf Docker-DNS geändert werden.

---

## Nginx

Nginx kann als Container oder Host-Proxy laufen.

Container:

```bash
PROXY_HOSTNAME=kundendomain.de PROXY_SOLR_HOSTNAME=solr.kundendomain.de \
  docker compose -f docker-compose.proxy.yml --profile nginx up -d
```

Host-Config generieren:

```bash
./nginx/generate-nginx-config.sh --instance prod --hostname solr.example.org --port 8983
```

Wichtig:

- `proxy_pass` mit sauberem Trailing Slash verwenden
- `Authorization` weiterreichen
- keine parallelen Host- und Container-Upstreams mischen

---

## SolrCloud und Standalone

| Modus | Hinweis |
|---|---|
| Standalone | Proxy kann Pfad-/Core-Isolation zusätzlich erzwingen |
| SolrCloud | Collection-ACLs isolieren direkt in Solr |

In beiden Modi bleibt der Proxy dumm: TLS terminieren, Header setzen, weiterleiten.
