# Monitoring-Integration

## Metriken-Endpunkt

Solr stellt Metriken bereit (BasicAuth, Support-User aus `.env`):

```
http://localhost:8983/solr/admin/metrics?wt=json
```

Auth: `SOLR_SUPPORT_USER` / `SOLR_SUPPORT_PASSWORD` aus `.env`

## Loki (Log-Aggregation)

Solr-Container schreibt Logs via Docker JSON-Driver (`json-file`, max 10MB, 3 Files).

Promtail-Beispiel fuer Loki-Integration:

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

## Prometheus (Groundwork)

Der Solr Prometheus Exporter ist im offiziellen Solr-Image enthalten.
Integration via separater `docker-compose.monitoring.yml` (kein eingebauter Service).
Credentials: `SOLR_SUPPORT_USER` / `SOLR_SUPPORT_PASSWORD` aus `.env`.

Siehe [Apache Solr Prometheus Exporter Docs](https://solr.apache.org/guide/solr/latest/deployment-guide/monitoring-with-prometheus-and-grafana.html).

## Empfohlene Alerts

| Alert | Schwelle |
|---|---|
| Container unhealthy | sofort |
| Backup-Log ERROR | taeglich pruefen |
| Disk > 80% (Backup-Dir) | taeglich pruefen |
