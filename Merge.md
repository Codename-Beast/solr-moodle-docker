# Merge Request

## Titel
**Fix/Doku: Solr-Moodle-Stack stabilisiert und auf aktuellen Stand gebracht**

## Beschreibung
Dieser Merge Request bringt den Solr-Moodle-Docker-Stack auf den aktuellen Stand und fasst die wichtigsten Verbesserungen zusammen.

### Was geändert wurde
- Startup- und Tenant-Flows stabilisiert
- Fehlerbehandlung bei Security-Reload, Core-Anlage und Tenant-Management verschärft
- Healthcheck-Verhalten überarbeitet
- Testabdeckung erweitert und angepasst
- Neue `proxy_guid.md` ergänzt
- Architektur-SVGs in die Doku eingebunden
- README und CI-/GitLab-Hinweise auf aktuellen Stand gebracht

### Inhaltlich wichtig
- Der Stack verhält sich jetzt klarer bei Fehlern im Tenant- oder Security-Setup
- Die Tests decken Standalone und SolrCloud sauber ab
- Die Doku ist näher am realen Betrieb und einfacher lesbar
- Proxy-Wege sind klar beschrieben
- Die README erklärt die relevanten Testläufe und typische Fehlermeldungen verständlich

### Verifikation
Lokal getestet, CI ist grün.

**Lokal**
- Shell-Syntax geprüft
- Testskripte ausgeführt
- Docker-/Stack-nahe Prüfungen bestanden

**CI**
- Lint erfolgreich
- Security Scan erfolgreich
- Standalone Core Tests erfolgreich
- SolrCloud Tests erfolgreich
