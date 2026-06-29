# Monitoring

Monitoring ist optional. Der Stack liefert Solr-Endpunkte, bringt aber keinen vollständigen Monitoring-Stack als Pflichtbestandteil mit.

---

## Endpunkte

| Zweck | Endpoint |
|---|---|
| Systeminfo | `/solr/admin/info/system` |
| Health | `/solr/admin/ping` |
| Metriken | `/solr/admin/metrics` |

Der Zugriff läuft über Basic Auth. Für Status- und Metrikabfragen ist der Support-User vorgesehen.

---

## Prometheus

Ein externer Prometheus kann lokal auf dem Host oder über den Proxy scrapen. Der Solr-Port sollte nicht öffentlich geöffnet werden.

```yaml
scrape_configs:
  - job_name: solr
    metrics_path: /solr/admin/metrics
    static_configs:
      - targets: ['127.0.0.1:8983']
```

---

## Logs

Runtime-Logs liegen unter `ELEDIA_LOG_ROOT`. Docker-Logs bleiben zusätzlich verfügbar:

```bash
docker compose logs --no-color solr
```

---

## Alerts

Sinnvolle Signale:

- HTTP-Status von `/solr/admin/ping`
- Heap und GC
- Query-/Update-Fehler
- Disk-Füllstand
- Container-Health
