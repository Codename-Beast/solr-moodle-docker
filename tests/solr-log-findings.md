# Solr Log Findings

Generated: 2026-05-27T14:30:00Z

## Scope
- Source: docker compose logs --tail=400 solr
- Focus: actionable WARN/ERROR/SEVERE related to Moodle/Solr indexing and query behavior

## ERROR/SEVERE

Historical (resolved):
- `coreNodeName missing` during SolrCloud startup when stale standalone core
  directories exist in the volume. Solr attempts to load them as Cloud cores,
  fails (expected), then recreates them properly via Collections API.
  No action needed if Collections API CREATE succeeds afterward (status=0).

## WARN
none

## URI length
none
