# Nginx Reverse Proxy für Solr

Nginx kann vor dem Solr-Stack TLS terminieren und Requests sauber an Solr weiterreichen.

## Varianten

### Variante A: Proxy läuft auf dem Host

Der Solr-Container published lokal auf `127.0.0.1:${SOLR_PORT}`. Nginx läuft direkt auf dem Host.

```nginx
proxy_pass http://127.0.0.1:8983;
```

### Variante B: Proxy läuft im Docker-Netzwerk

Der Proxy-Service befindet sich im selben Docker-Netzwerk wie der Solr-Service und spricht den Compose-Service-Namen an.

```nginx
proxy_pass http://solr:8983;
```

Wichtig: In einer aktiven Konfiguration genau eine `proxy_pass`-Variante verwenden.

## Konfiguration generieren

```bash
./nginx/generate-nginx-config.sh --instance prod --hostname solr.example.com --port 8983
```

Die generierte Datei liegt unter:

```text
nginx/generated/solr-prod.conf
```

## Prüfen und aktivieren

```bash
sudo cp nginx/generated/solr-prod.conf /etc/nginx/sites-available/
sudo ln -sf /etc/nginx/sites-available/solr-prod.conf /etc/nginx/sites-enabled/solr-prod.conf
sudo nginx -t
sudo systemctl reload nginx
```

## Betriebshinweise

- TLS endet am Proxy.
- `Host`, `X-Forwarded-Host`, `X-Forwarded-Proto` und `X-Forwarded-For` werden gesetzt.
- Basic-Auth wird an Solr weitergereicht.
- Keine Pfad-Rewrites einbauen, wenn Solr bereits unter dem erwarteten Pfad erreichbar ist.
- Für Moodle muss die Secure-/HTTPS-Einstellung zum externen Proxy-Endpunkt passen.
