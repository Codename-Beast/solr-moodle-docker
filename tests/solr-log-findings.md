# Solr Log Findings

Generated: 2026-05-30T18:13:31Z

## Scope
- Source: docker compose logs --tail=400 solr
- Focus: actionable WARN/ERROR/SEVERE related to Moodle/Solr indexing and query behavior

## ERROR/SEVERE
```
ci-local-solr  | 2026-05-30 18:13:23.989 ERROR (qtp566113173-19-null-60) [ x:eLeDia_core t:null-60] o.a.s.h.RequestHandlerBase Client exception =>org.apache.solr.common.SolrException: Error CREATEing SolrCore 'eLeDia_core': coreNodeName missing {configSet=eLeDia-moodle-tenant}
```

## WARN
none

## URI length
none

