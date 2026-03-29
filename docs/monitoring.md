# Monitoring-Integration

Solr laeuft mit einem dedizierten `support`-User (read-only) fuer Monitoring-Zugriff.
Credentials stehen in `.env`: `SOLR_SUPPORT_USER` / `SOLR_SUPPORT_PASSWORD`.

## Metriken-Endpunkt

```
http://localhost:8983/solr/admin/metrics?wt=json
```

Auth: support-User aus `.env`

## Prometheus

Der Solr Prometheus Exporter ist im offiziellen Solr-Image enthalten.

Minimales Beispiel (eigene `docker-compose.monitoring.yml`):

```yaml
services:
  solr-exporter:
    image: solr:${SOLR_VERSION:-9.10.1}
    container_name: ${INSTANCE_NAME:-solr}-exporter
    entrypoint:
      - "/bin/sh"
      - "-c"
      - >-
        /opt/solr/contrib/prometheus-exporter/bin/solr-exporter
        -p 9854
        -b http://$${SOLR_SUPPORT_USER}:$${SOLR_SUPPORT_PASSWORD}@${INSTANCE_NAME:-solr}-solr:${SOLR_PORT:-8983}/solr
        -f /opt/solr/contrib/prometheus-exporter/conf/solr-exporter-config.xml
        -n 8
    ports:
      - "127.0.0.1:9854:9854"
    env_file:
      - .env
    networks:
      - ${INSTANCE_NAME:-solr}-network
    restart: unless-stopped
```

Starten:
```bash
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d solr-exporter
```

Prometheus scrape config:
```yaml
scrape_configs:
  - job_name: solr
    static_configs:
      - targets: ["localhost:9854"]
```

## Loki (Log-Aggregation)

Solr-Logs via Docker JSON-Driver (max 10MB, 3 Files). Promtail-Beispiel:

```yaml
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

## Empfohlene Alerts

| Alert | Schwelle | Kanal |
|---|---|---|
| Container unhealthy | sofort | PagerDuty/Slack |
| Backup-Log ERROR | taegliche Pruefung | E-Mail |
| Disk > 80% (Backup-Dir) | taegliche Pruefung | E-Mail |
| Solr JVM Heap > 85% | 5min sustained | Slack |
