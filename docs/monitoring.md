# Monitoring-Integration

> Monitoring ist optional. Der Stack enthält keinen eingebauten Monitoring-Service.
> Integration läuft über separate `docker-compose.monitoring.yml` (nicht im Repo enthalten).

---

## Metriken-Endpunkt

Solr stellt Metriken bereit (BasicAuth erforderlich):

```
http://localhost:${SOLR_PORT:-8983}/solr/admin/metrics?wt=json
```

Auth: `SOLR_SUPPORT_USER` / `SOLR_SUPPORT_PASSWORD` aus `.env`

---

## Prometheus

Der Solr Prometheus Exporter ist im offiziellen Solr-Image enthalten.

Beispiel-Integration via separatem Compose-File:

```yaml
# docker-compose.monitoring.yml
services:
  prometheus:
    image: prom/prometheus:latest
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
    network_mode: host   # direkt auf 127.0.0.1:${SOLR_PORT}
```

Credentials: `SOLR_SUPPORT_USER` / `SOLR_SUPPORT_PASSWORD` aus `.env`.

Dokumentation: [Apache Solr Prometheus Exporter](https://solr.apache.org/guide/solr/latest/deployment-guide/monitoring-with-prometheus-and-grafana.html)

---

## Loki (Log-Aggregation)

Solr-Container schreibt Logs via Docker JSON-Driver (`json-file`, max 10MB, 3 Dateien).

Promtail-Beispiel:

```yaml
# promtail-config.yaml
scrape_configs:
  - job_name: solr
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
        filters:
          - name: name
            values: ["${INSTANCE_NAME:-solr}-solr"]
    relabel_configs:
      - source_labels: [__meta_docker_container_name]
        target_label: container
```

---

## Empfohlene Alerts

| Alert | Schwelle | Priorität |
|-------|----------|-----------|
| Container unhealthy | sofort | kritisch |
| Backup-Log ERROR | täglich prüfen | hoch |
| Disk > 80% (Backup-Verzeichnis) | täglich prüfen | mittel |
| Heap-Nutzung > 85% | täglich prüfen | mittel |

---

## Vollständiges Monitoring-Setup

Für ein vollständiges Monitoring-Setup (Prometheus + Grafana + Loki + Alloy)
steht die [ansible-role-solr](https://github.com/Codename-Beast/ansible-role-solr)
zur Verfügung — diese richtet den kompletten Monitoring-Stack automatisiert ein.
