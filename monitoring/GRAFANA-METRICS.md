# Grafana Dashboard - Verfügbare Metriken

## Developer: BSC Bernd Schreistetter | Company: Eledia.de | Version: v.0

##  SOLR METRIKEN (automatisch verfügbar):

### Core Performance:
- `solr_metrics_core_requests_total` - Anzahl Requests pro Core
- `solr_metrics_core_request_time_ms` - Request Latency
- `solr_metrics_core_index_size_bytes` - Index Größe
- `solr_metrics_core_searcher_documents` - Anzahl Dokumente

### JVM & Memory:
- `solr_metrics_jvm_memory_heap_bytes_used` - Heap Usage
- `solr_metrics_jvm_memory_heap_bytes_max` - Max Heap
- `solr_metrics_jvm_threads_count` - Thread Count
- `solr_metrics_jvm_gc_seconds_total` - Garbage Collection

### HTTP/Jetty:
- `solr_metrics_jetty_requests_total{method="get"}` - HTTP GET Requests
- `solr_metrics_jetty_dispatches_total` - Request Dispatches
- `solr_metrics_jetty_request_time_ms` - HTTP Latency

### Cache Performance:
- `solr_metrics_core_cache{cache="queryResultCache"}` - Query Cache
- `solr_metrics_core_cache{cache="filterCache"}` - Filter Cache
- `solr_metrics_core_cache{cache="documentCache"}` - Document Cache

## 🐳 DOCKER METRIKEN (via cAdvisor - optional):
- Container CPU Usage
- Container Memory Usage
- Network I/O
- Disk I/O

##  SERVER METRIKEN (via Node Exporter - optional):
- CPU Load
- Memory Usage
- Disk Space
- Network Traffic

##  GRAFANA DASHBOARD PANELS (Empfehlung):

### Row : Overview
. Total Requests (Counter)
. Active Cores (Gauge)
. Index Size (Gauge)
. Documents Count (Gauge)

### Row : Performance
. Request Rate (Graph - requests/sec)
. Request Latency (Graph - P50, P95, P99)
. Cache Hit Ratio (Graph)

### Row : Resources
. JVM Heap Usage (Graph + Gauge)
. Thread Count (Graph)
. GC Time (Graph)

### Row : HTTP
. HTTP Status Codes (Bar Chart)
. Request Methods Distribution (Pie Chart)
. Top Endpoints (Table)

## 📝 Grafana Query Examples:

```promql
# Requests per second
rate(solr_metrics_core_requests_total[5m])

# Average request time
rate(solr_metrics_core_request_time_ms_sum[5m]) / rate(solr_metrics_core_request_time_ms_count[5m])

# Heap usage percentage
(solr_metrics_jvm_memory_heap_bytes_used / solr_metrics_jvm_memory_heap_bytes_max) * 00

# Cache hit rate
rate(solr_metrics_core_cache{type="hits"}[5m]) / (rate(solr_metrics_core_cache{type="hits"}[5m]) + rate(solr_metrics_core_cache{type="misses"}[5m])) * 00
```

##  Zugriff:
- Grafana: http://<server-ip>:000
- Login: admin / admin (beim ersten Login ändern!)
- Datasource: Prometheus (automatisch konfiguriert)
