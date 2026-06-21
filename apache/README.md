# 🌐 Apache Reverse Proxy Templates

Die Apache-Templates sind für Setups gedacht, bei denen Solr nicht direkt erreichbar sein soll. Apache nimmt HTTPS an und leitet intern auf den lokalen Solr-Port weiter.

---

## Grundidee

```text
Moodle / Browser -> HTTPS -> Apache -> 127.0.0.1:${SOLR_PORT}
```

Solr selbst bleibt lokal gebunden.

---

## Dateien

| Datei | Zweck |
|---|---|
| `generate-apache-config.sh` | erzeugt Apache-Konfigurationen aus `.env` |
| Template-Dateien | Proxy-Regeln für `/solr` und Tenant-Zugriffe |

---

## Nutzung

```bash
./apache/generate-apache-config.sh
```

Danach die erzeugte Konfiguration prüfen und in Apache aktivieren.

---

## Wichtige Punkte

- TLS gehört auf den Proxy.
- Solr soll nicht auf `0.0.0.0` lauschen.
- Basic Auth Header müssen sauber weitergereicht werden.
- Bei Tenant-Subdomains müssen die Hostnamen zum Moodle-/Proxy-Konzept passen.
