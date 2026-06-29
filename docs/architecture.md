# Architektur — solr-moodle-docker

Kurzüberblick über Bootstrap, Runtime und Tenant-Management.

![Installation und Bootstrap](architecture-install.svg)

![Runtime Architektur](architecture-runtime.svg)

---

## Komponenten

| Komponente | Aufgabe |
|---|---|
| `docker-compose.yml` | Stack, Volumes, Ports, Healthchecks |
| `eLeDia-solr-init` | Bootstrap: Security-Basis, Configsets, Marker |
| `solr` | Runtime für Cores oder Collections |
| `scripts/solr-tenant.sh` | Tenant-CLI für create, passwd, sync, export und Drift |
| `eLeDia-config/` | Moodle-Schema, `/update/extract`, Ping-Handler |
| `docker-compose.proxy.yml` | optionale Caddy-/Nginx-Proxy-Container |

---

## Startablauf

```text
docker compose up -d
  -> eLeDia-solr-init
  -> security.json + Configsets + Ping-Healthcheck-Datei
  -> solr Runtime
  -> Tenant-CLI / Moodle / Proxy
```

Der Runtime-Container startet erst nach erfolgreichem Init. Kaputte Security- oder Pflichtpasswort-Zustände stoppen früh.

---

## Runtime

```text
Moodle -> Reverse Proxy -> Solr API -> Core/Collection
```

| Modus | Objekt | Isolation | Persistenz |
|---|---|---|---|
| Standalone | Core | Security + Proxy-Regeln | Docker Volume |
| SolrCloud | Collection | Security API + Collection-ACLs | Docker Volume + ZooKeeper |

SolrCloud ist der Default. Die Tenant-Befehle bleiben in beiden Modi gleich.

---

## Tenant-Rechte

- Jeder Tenant bekommt einen eigenen Solr-User.
- Rechte werden aus `tenants.env` und Runtime-Daten aufgebaut.
- Tenant-Regeln stehen vor der breiten Fallback-Permission `all`.
- `runtime-truth` liest den Live-Zustand aus Solr API und ZooKeeper.
- `drift-detect` vergleicht Sollzustand und Runtime.

---

## Tika und Moodle-Dokumente

Moodle nutzt `/update/extract`, um Dateiinhalte zu indexieren.

```text
PDF/DOCX/HTML -> /update/extract -> solr_filecontent -> Moodle Suche
```

Die Tests prüfen deshalb echte Inhaltsabfragen, nicht nur Container-Liveness.
