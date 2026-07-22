# Moodle Solr Suche optimal einstellen

Diese Notiz beschreibt den praxistauglichen Betrieb von Moodle Global Search mit dem eLeDia Solr Docker Stack.

## Grundprinzip

Moodle ersetzt damit nicht die komplette Moodle-Datenbank.

Moodle nutzt die Datenbank weiterhin fuer Rechte, Kurse, Aktivitaeten, Nutzer, Kontext, Verfuegbarkeit und Metadaten. Die eigentliche Volltextsuche laeuft aber nicht mehr ueber DB-`LIKE` oder Moodle-simple-search, sondern ueber die Search API und den aktiven Search-Engine-Backend `search_solr`.

Ablauf:

1. Moodle erzeugt Search-Dokumente aus Kursen, Aktivitaeten, Foren, Dateien usw.
2. Moodle sendet diese Dokumente an Solr.
3. Bei aktivierter Dateiindexierung sendet Moodle Dateien an Solr `/update/extract`; Solr/Tika extrahiert PDF, DOCX, PPTX, TXT, HTML, CSV, RTF usw.
4. Suchanfragen laufen ueber Moodle Global Search gegen Solr.
5. Moodle filtert/validiert Ergebnisse weiterhin gegen Moodle-Rechte und Kontexte.
6. Fallback auf DB-Suche passiert nur, wenn ein Moodle-Bereich/Plugin nicht in Global Search integriert ist oder Global Search nicht aktiv ist.

## Solr-Stack Voraussetzungen

Der Stack stellt fuer Moodle bereit:

- Configset: `eLeDia-moodle-tenant`
- Default-Configset: `_default` wird ebenfalls mit Moodle-Schema versorgt
- Schema API: `/schema`
- Dateiindexierung: `/update/extract`
- Tika-Modul: `SOLR_MODULES=extraction`
- Datei-Inhaltsfeld: `solr_filecontent`
- Moodle-Hauptfelder: `title`, `content`, `description1`, `description2`, `contextid`, `courseid`, `owneruserid`, `modified`, `type`, `areaid`, `itemid`
- optimierter Diagnose-/Probe-Handler: `/moodle` mit `edismax`, Boosts und `solr_filecontent`

Wichtig: Der Stack stellt das Configset bereit. Moodle muss beim ersten Verbinden trotzdem sein Search-Schema bzw. den Admin-Check gegen genau den Ziel-Core/die Ziel-Collection ausfuehren.

## Moodle Einstellungen

In Moodle:

`Site administration -> Plugins -> Search -> Manage global search`

Empfohlen:

- Global search: aktiv
- Search engine: `Solr`

`Site administration -> Plugins -> Search -> Solr`

Docker-Moodle im gleichen Docker-Netz:

- Server hostname: Containername, z. B. `itestsolr-solr`
- Server port: interner Solr-Port, z. B. `19083` in diesem Teststack
- Index name: Tenant-Core/-Collection, z. B. `eLeDia_core`
- Username: Tenant-User, z. B. `solr_<tenant>`
- Password: Tenant-Passwort aus `tenants.env`
- File indexing: aktiv
- Max file size: passend zur Moodle-Instanz und Heap groessen, z. B. 10-100 MB
- Secure mode/SSL: nur aktivieren, wenn der Proxy/TLS-Pfad genutzt wird

Moodle auf demselben Host, aber nicht im Docker:

- Server hostname: `127.0.0.1` oder Proxy-Hostname
- Server port: Host-Bind-Port, z. B. `19083`
- Index name: derselbe Tenant-Core, z. B. `eLeDia_core`
- Credentials: Tenant-Credentials, nicht Admin-Credentials

Produktiv besser:

- Solr nur an `127.0.0.1` binden oder hinter Reverse Proxy betreiben
- TLS am Proxy
- Tenant-User statt Admin-User in Moodle
- Core/Collection pro Tenant sauber trennen

## Schema initialisieren

Nach der Moodle-Konfiguration:

1. In Moodle Admin den Solr-Status/Schema-Check ausfuehren.
2. Oder per CLI sinngemaess das Moodle-Solr-Schema initialisieren.
3. Danach Index bauen.

Beispiel im Moodle-Codeverzeichnis:

```bash
php admin/cli/cfg.php --name=enableglobalsearch --set=1
php admin/cli/cfg.php --name=searchengine --set=solr
php admin/cli/cfg.php --component=search_solr --name=fileindexing --set=1
php search/cli/indexer.php --force
```

Je nach Moodle-Version gibt es keinen einzelnen offiziellen CLI-Befehl fuer alle Solr-Settings. In Automatisierung kann man die Werte per `admin/cli/cfg.php --component=search_solr` setzen und danach den Admin-Check bzw. Schema-Setup ausfuehren.

## Indexieren

Einmaliger Vollindex:

```bash
php search/cli/indexer.php --force
```

Regelbetrieb:

```bash
php admin/cli/cron.php
```

Gezielter Task:

```bash
php admin/cli/scheduled_task.php --execute='\core\task\search_index_task' --force
```

Nach grossen Imports, Restore oder Migration:

```bash
php search/cli/indexer.php --force
php admin/cli/cron.php
```

## Was muss man testen?

### 1. Solr Configset und Schema

Im Solr-Container:

```bash
docker exec <solr-container> /opt/solr/scripts/solr-tenant.sh healthcheck
```

Erwartet:

```text
Healthcheck passed ... schema=ok
```

Dieser Healthcheck prueft:

- Solr System API erreichbar
- Auth aktiv
- `solr_filecontent` vorhanden
- `/update/extract` vorhanden
- in SolrCloud: Collection nutzt `eLeDia-moodle-tenant`

### 2. Self-Healing bei kaputten Configsets

Wenn Configsets, `_default`, ZooKeeper-Config oder Handler kaputt sind:

```bash
docker exec <solr-container> /opt/solr/scripts/solr-tenant.sh config-repair
```

Das macht:

- `managed-schema` und `solrconfig.xml` aus `/opt/solr/eledia-config` oder Image-Fallback neu kopieren
- `eLeDia-moodle-tenant` und `_default` auffrischen
- in SolrCloud Configset nach ZooKeeper hochladen
- Tenant-Collections/Cores reloaden
- abschliessend Healthcheck ausfuehren

### 3. Dateiindexierung

Mindestens testen:

- PDF mit eindeutigem Marker
- DOCX mit eindeutigem Marker
- PPTX mit eindeutigem Marker
- ein echter Inhaltsbegriff pro Datei, nicht nur Dateiname/Titel

Im E2E-Test wurden erfolgreich gefunden:

- PDF Marker: `PDF_MARKER_ELEDIA_SOLR_TIKA_1784763001`
- PDF Inhalt: `Rechnungsfreigabe`
- DOCX Marker: `DOCX_MARKER_ELEDIA_SOLR_TIKA_1784763002`
- DOCX Inhalt: `Vertragsanlage`
- PPTX Marker: `PPTX_MARKER_ELEDIA_SOLR_TIKA_1784763003`
- PPTX Inhalt: `Schulungsfolie`

Wichtig: Fuer PPTX echte gueltige Office-Dateien verwenden. Handgebaute ZIP/XML-Dateien koennen formal wie OOXML aussehen, aber von Apache Tika trotzdem abgelehnt werden.

### 4. Query-/Tuning-Vergleich

Der Stack bringt einen kleinen Vergleichstest mit:

```bash
SOLR_HOST=127.0.0.1 \
SOLR_PORT=19083 \
SOLR_CORE=eLeDia_core \
SOLR_USER='<tenant-user>' \
SOLR_PASS='<tenant-pass>' \
./scripts/test-moodle-search-tuning.sh
```

Der Test vergleicht:

- `/select` default
- `/select` mit `content OR solr_filecontent OR title`
- `/moodle` optimierter eDisMax-Handler
- `/moodle` mit Moodle-typischem `areaid`-Filter

Ausgabe enthaelt pro Profil:

- HTTP-Code
- Trefferzahl
- Solr `QTime`
- Curl-Gesamtzeit

Damit kann man verschiedene Einstellungen vergleichen, ohne Solr-Zustand zu veraendern.

## Sinnvolle Tuning-Regeln

### Heap und Caches

Kleine Instanz / wenige Cores:

- `SOLR_HEAP=2g`
- Cache defaults 512 sind ok

Viele Tenants/Cores:

- Heap erhoehen
- Cache pro Core kleiner halten, z. B. 256
- nicht jeden Core maximal cachen, sonst frisst Cache den Heap

Relevante Solr-Properties in `SOLR_OPTS`:

```text
-Dsolr.filterCache.size=512
-Dsolr.queryResultCache.size=512
-Dsolr.documentCache.size=512
-Dsolr.max.booleanClauses=2048
-Dsolr.autoSoftCommit.maxTime=1000
-Dsolr.autoCommit.maxTime=15000
-Dsolr.multipartUploadLimitKB=102400
```

### Dateiindexierung

- `fileindexing=1` in Moodle aktivieren
- Solr `SOLR_MODULES=extraction`
- Upload-Limit nicht unendlich gross setzen
- Moodle Max-File-Size realistisch setzen
- grosse Dateien per Cron indexieren, nicht waehrend Spitzenlast

### Core/Collection Zuordnung

- Moodle `indexname` muss exakt dem Tenant-Core/der Tenant-Collection entsprechen
- In SolrCloud muss die Collection mit `collection.configName=eLeDia-moodle-tenant` erstellt sein
- Keine Cores manuell ohne Configset anlegen
- Wenn doch passiert: `config-repair` und ggf. Core/Collection neu mit Tenant-Helper anlegen

### Rechte und Sicherheit

- Moodle nutzt Tenant-Credentials, nicht Admin
- Admin-Zugang nur fuer Betrieb/Repair
- Direktzugriff im Standalone-Modus nur lokal oder ueber Proxy isolieren
- SolrCloud bevorzugen, wenn echte Collection-Isolation gebraucht wird

## Fehlersuche

`enginenotinstalled` in Moodle:

- PHP-Solr-Extension fehlt oder wird von Moodle nicht erkannt
- falsches Moodle-Image/PHP-FPM
- Search engine nicht auf `solr`

`server_ready=false`:

- falscher Host/Port
- falsche Credentials
- falscher Core/Collection-Name
- Schema-Setup noch nicht gelaufen

Dateiname wird gefunden, aber Inhalt nicht:

- `fileindexing=0`
- `/update/extract` fehlt
- Tika/Extraction-Modul fehlt
- Datei ist nicht wirklich indexierbar oder defekt
- Moodle-Cron/Indexer lief noch nicht

Healthcheck ohne `schema=ok`:

- Configset kaputt oder falsche Collection
- ausfuehren:

```bash
docker exec <solr-container> /opt/solr/scripts/solr-tenant.sh config-repair
```
