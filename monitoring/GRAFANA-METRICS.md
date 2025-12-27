# Grafana Dashboard - Verfügbare Metriken

## Developer: BSC Bernd Schreistetter | Company: Eledia.de | Version: v2.0

## 📊 SOLR METRIKEN (automatisch verfügbar):

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

## 🖥️ SERVER METRIKEN (via Node Exporter - optional):
- CPU Load
- Memory Usage
- Disk Space
- Network Traffic

## 🎯 GRAFANA DASHBOARD PANELS (Empfehlung):

### Row 1: Overview
1. Total Requests (Counter)
2. Active Cores (Gauge)
3. Index Size (Gauge)
4. Documents Count (Gauge)

### Row 2: Performance
1. Request Rate (Graph - requests/sec)
2. Request Latency (Graph - P50, P95, P99)
3. Cache Hit Ratio (Graph)

### Row 3: Resources
1. JVM Heap Usage (Graph + Gauge)
2. Thread Count (Graph)
3. GC Time (Graph)

### Row 4: HTTP
1. HTTP Status Codes (Bar Chart)
2. Request Methods Distribution (Pie Chart)
3. Top Endpoints (Table)

## 📝 Grafana Query Examples:

```promql
# Requests per second
rate(solr_metrics_core_requests_total[5m])

# Average request time
rate(solr_metrics_core_request_time_ms_sum[5m]) / rate(solr_metrics_core_request_time_ms_count[5m])

# Heap usage percentage
(solr_metrics_jvm_memory_heap_bytes_used / solr_metrics_jvm_memory_heap_bytes_max) * 100

# Cache hit rate
rate(solr_metrics_core_cache{type="hits"}[5m]) / (rate(solr_metrics_core_cache{type="hits"}[5m]) + rate(solr_metrics_core_cache{type="misses"}[5m])) * 100
```

## 🚀 Zugriff:
- Grafana: http://<server-ip>:3000
- Login: admin / admin (beim ersten Login ändern!)
- Datasource: Prometheus (automatisch konfiguriert)
