# 🧱 Architektur — solr-moodle-docker

Diese Datei beschreibt den Docker-Stack hinter Moodle Global Search. Kurz gehalten, damit man im Betrieb schnell sieht, welche Komponente wofür zuständig ist.

![Architektur — Installation und Bootstrap](architecture-install.svg)
![Architektur — Runtime](architecture-runtime.svg)

---

## Inhalt

| Bereich | Inhalt |
|---|---|
| 🧩 Komponenten | Init-Container, Solr Runtime, Tenant-CLI |
| 🔁 Ablauf | Start, Bootstrap, Runtime |
| 🔐 Security | AuthN/AuthZ, Tenant-Rechte, Fallback-Regel |
| ☁ SolrCloud | Collections, ZooKeeper, Runtime-SOT |
| 🧪 Tests | Tika, Tenant-Isolation, Drift |

---

## 🧩 Komponenten

| Komponente | Aufgabe |
|---|---|
| `docker-compose.yml` | Stack-Definition, Volumes, Ports, Healthchecks |
| `eLeDia-solr-init` | schreibt Security-Basis und Configsets vor dem Runtime-Start |
| `solr` | Solr Runtime für Cores oder Collections |
| `init/powerinit.sh` | Bootstrap-Logik für `security.json` und Configsets |
| `scripts/solr-tenant.sh` | Tenant-CLI für create, passwd, sync, export und Drift-Checks |
| `eLeDia-config/` | Moodle-Schema und `/update/extract` für Tika |

---

## 🔁 Startablauf

```text
docker compose up -d
  -> eLeDia-solr-init
  -> security.json + Configsets
  -> solr Runtime
  -> Tenant-CLI / Moodle / Proxy
```

Der Runtime-Container startet erst nach erfolgreichem Init. Das reduziert Race Conditions beim ersten Start und bei Updates.

---

## 🔐 Security und Tenant-Rechte

- Solr bindet lokal auf `127.0.0.1:${SOLR_PORT}`.
- Externe Zugriffe laufen über Apache, Caddy oder einen anderen Reverse Proxy.
- Jeder Tenant bekommt einen eigenen Solr-User.
- Tenant-Rechte werden aus `tenants.env` und Runtime-Daten aufgebaut.
- Die Fallback-Permission `all` bleibt zuletzt, damit tenant-spezifische Regeln nicht überdeckt werden.

---

## ☁ SolrCloud

Im SolrCloud-Modus nutzt Moodle Collections statt Cores. Die Tenant-Befehle bleiben gleich.

| Punkt | Standalone | SolrCloud |
|---|---|---|
| Objekt | Core | Collection |
| Isolation | Security + Proxy | Collections + Security API |
| Persistenz | Volume | Volume + ZooKeeper |

Die Runtime Source of Truth liegt in Solr bzw. ZooKeeper. Das ist auch die Grundlage für Drift-Erkennung und Export.

---

## 🧪 Tika und Dokumenttests

Moodle nutzt `/update/extract`, um Dateiinhalte zu indexieren. Die Tests prüfen deshalb nicht nur einen technischen Marker, sondern auch eine normale Inhaltsabfrage.

```text
PDF/DOCX/HTML -> /update/extract -> solr_filecontent -> Moodle Suche
```

---

## Nicht im Scope

- Kubernetes oder Helm
- externer ZooKeeper-Cluster-Manager
- TLS-Konfiguration im Solr-Container selbst
- öffentliche Freigabe des Solr-Ports
