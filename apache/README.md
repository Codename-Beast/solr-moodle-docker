# Apache Reverse Proxy für Solr

Apache ist für klassische Host-Setups gedacht: HTTPS endet auf Apache, intern geht es auf den lokal gebundenen Solr-Port.

```text
Browser / Moodle -> HTTPS -> Apache -> 127.0.0.1:${SOLR_PORT}/solr/
```

Solr bleibt lokal gebunden.

---

## Nutzung

```bash
./apache/generate-apache-config.sh
```

Danach die erzeugte Datei prüfen, in Apache aktivieren und Apache neu laden.

---

## Regeln

- TLS endet am Proxy.
- `ProxyPreserveHost On` setzen.
- `X-Forwarded-Proto https` setzen.
- Basic Auth Header weiterreichen.
- Solr nicht auf `0.0.0.0` öffnen.
- Wenn Apache als Container läuft, statt `127.0.0.1` den Docker-DNS-Namen nutzen.
