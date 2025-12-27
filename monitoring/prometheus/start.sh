#!/bin/sh
# Purpose: Render a Prometheus config into /tmp (writable) and start Prometheus as non-root.
set -eu

PORT="${PROMETHEUS_PORT:-9090}"
METRICS_USER="${SOLR_METRICS_USER:-support}"
METRICS_PASS="${SOLR_METRICS_PASSWORD:-eledia_default}"

cat > /tmp/prometheus.yml <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: solr
    metrics_path: /solr/admin/metrics
    params:
      wt: [prometheus]
    basic_auth:
      username: "${METRICS_USER}"
      password: "${METRICS_PASS}"
    static_configs:
      - targets: ["solr:8983"]
EOF

exec /bin/prometheus \
  --config.file=/tmp/prometheus.yml \
  --storage.tsdb.path=/prometheus \
  --web.listen-address=":${PORT}"
