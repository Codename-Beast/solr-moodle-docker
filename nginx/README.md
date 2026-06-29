# Nginx Reverse Proxy für Solr

Nginx kann vor dem Solr-Stack TLS terminieren und Requests sauber an Solr weiterreichen.

## Varianten

### Variante A: Proxy läuft auf dem Host

Der Solr-Container published lokal auf `127.0.0.1:${SOLR_PORT}`. Nginx läuft direkt auf dem Host.

```nginx
proxy_pass http://127.0.0.1:8983/solr/;
```

### Variante B: Proxy läuft im Docker-Netzwerk

Der Proxy-Service befindet sich im selben Docker-Netzwerk wie der Solr-Service. Dann nutzt er Docker-DNS statt Host-Loopback. Der Containername folgt hier normalerweise `${INSTANCE_NAME:-solr}-solr`, also z. B. `solr-solr` oder `prod-solr`. `solr` funktioniert nur, wenn dieser Alias explizit existiert.

Wichtig: Ein anderer Container sieht das Solr-Netzwerk nicht automatisch. Nginx muss explizit an das Solr-Netzwerk gehängt werden:

```bash
docker network connect solr-network <nginx-container>
```

Oder per Compose:

```yaml
networks:
  solr_network:
    external: true
    name: solr-network
```

Bei `INSTANCE_NAME=prod` wäre der Netzwerkname typischerweise `prod-network`.

```nginx
proxy_pass http://<containername>:<solr-port>/solr/;
```

Wichtig: In einer aktiven Konfiguration genau eine `proxy_pass`-Variante verwenden.

## Nginx als Container starten

```bash
PROXY_HOSTNAME=kundendomain.de PROXY_SOLR_HOSTNAME=solr.kundendomain.de \
  docker compose -f docker-compose.proxy.yml --profile nginx up -d
```

Der Container wird automatisch an `${INSTANCE_NAME:-solr}-network` gehängt und nutzt intern `${INSTANCE_NAME:-solr}-solr:${SOLR_PORT:-8983}`. Er bedient `https://kundendomain.de/solr` und `https://solr.kundendomain.de`. Abweichende Namen/Ports:

```bash
SOLR_UPSTREAM=my-solr-container:18983 PROXY_HOSTNAME=kundendomain.de \
  PROXY_SOLR_HOSTNAME=solr.kundendomain.de \
  docker compose -f docker-compose.proxy.yml --profile nginx up -d
```

Nginx braucht Zertifikate unter `nginx/certs/fullchain.pem` und `nginx/certs/privkey.pem`. Wenn automatische TLS-Verwaltung gewünscht ist, nimm Caddy.

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

- Extern läuft der Zugriff über HTTPS; TLS endet am Proxy.
- Intern vom Proxy zu Solr ist HTTP (`http://<containername>:<solr-port>`) korrekt.
- `Host`, `X-Forwarded-Host`, `X-Forwarded-Proto` und `X-Forwarded-For` werden gesetzt.
- Basic-Auth wird an Solr weitergereicht.
- Keine Pfad-Rewrites einbauen, wenn Solr bereits unter dem erwarteten Pfad erreichbar ist.
- Für Moodle muss die Secure-/HTTPS-Einstellung zum Endpunkt passen, den Moodle selbst nutzt: öffentlicher HTTPS-Proxy => Secure an; internes HTTP im Docker-Netzwerk => Secure aus.
