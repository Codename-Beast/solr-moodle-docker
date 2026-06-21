# 📈 Monitoring

Monitoring ist optional. Der Stack liefert Solr-Metriken, aber er bringt keinen vollständigen Monitoring-Betrieb als Pflichtbestandteil mit.

---

## Endpunkte

| Zweck | Endpoint |
|---|---|
| Systeminfo | `/solr/admin/info/system` |
| Health | `/solr/admin/ping` |
| Metriken | `/solr/admin/metrics` |

Der Zugriff läuft über Basic Auth. Für reine Status- und Metrikabfragen ist der Support-User vorgesehen.

---

## Prometheus

Ein externer Prometheus kann Solr-Metriken über den Proxy oder lokal auf dem Host abfragen. Wichtig ist, dass der Solr-Port nicht öffentlich geöffnet wird.

Beispielidee:

```yaml
scrape_configs:
  - job_name: solr
    metrics_path: /solr/admin/metrics
    static_configs:
      - targets: ['127.0.0.1:8983']
```

---

## Logs

Runtime-Logs liegen unter dem in `.env` gesetzten `ELEDIA_LOG_ROOT`. Container-Logs bleiben zusätzlich über Docker verfügbar:

```bash
docker compose logs --no-color solr
```

---

## Hinweise

- Kein direkter öffentlicher Zugriff auf Solr nur für Monitoring.
- Alerts sollten HTTP-Status, Heap, Query-Fehler und Disk-Füllstand abdecken.
- Für produktive Dashboards ist der externe Monitoring-Stack zuständig.
