# Nginx Reverse Proxy für Solr

Nginx kann als Container im Solr-Netzwerk laufen oder auf dem Host TLS terminieren.

---

## Container-Modus

```bash
PROXY_HOSTNAME=kundendomain.de PROXY_SOLR_HOSTNAME=solr.kundendomain.de \
  docker compose -f docker-compose.proxy.yml --profile nginx up -d
```

Der Container wird automatisch an `${INSTANCE_NAME:-solr}-network` gehängt.
Interner Default-Upstream:

```text
${INSTANCE_NAME:-solr}-solr:${SOLR_PORT:-8983}
```

Erreichbar danach:

```text
https://kundendomain.de/solr
https://solr.kundendomain.de    # redirectet nach /solr/
```

Abweichender Upstream:

```bash
SOLR_UPSTREAM=my-solr-container:18983 \
PROXY_HOSTNAME=kundendomain.de \
PROXY_SOLR_HOSTNAME=solr.kundendomain.de \
  docker compose -f docker-compose.proxy.yml --profile nginx up -d
```

Nginx braucht Zertifikate unter:

```text
nginx/certs/fullchain.pem
nginx/certs/privkey.pem
```

Wenn TLS automatisch verwaltet werden soll, nimm Caddy.

---

## Host-Modus

Der Solr-Container published lokal auf `127.0.0.1:${SOLR_PORT}`. Nginx läuft direkt auf dem Docker-Host.

```nginx
proxy_pass http://127.0.0.1:8983/solr/;
```

Config generieren:

```bash
./nginx/generate-nginx-config.sh --instance prod --hostname solr.example.com --port 8983
```

Ausgabe:

```text
nginx/generated/solr-prod.conf
```

Aktivieren:

```bash
sudo cp nginx/generated/solr-prod.conf /etc/nginx/sites-available/
sudo ln -sf /etc/nginx/sites-available/solr-prod.conf /etc/nginx/sites-enabled/solr-prod.conf
sudo nginx -t
sudo systemctl reload nginx
```

---

## Regeln

- Extern HTTPS, intern HTTP zu Solr.
- `Host`, `X-Forwarded-Host`, `X-Forwarded-Proto` und `X-Forwarded-For` setzen.
- `Authorization` an Solr weiterreichen.
- Keine unnötigen Pfad-Rewrites.
- Genau eine Upstream-Variante nutzen: Host-Port oder Docker-Netzwerk.
