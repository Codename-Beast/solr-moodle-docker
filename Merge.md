# Merge-Text

## Titel

Solr-Moodle-Stack 3.4.10: Tenant-Management, Proxy-Betrieb und CI stabilisiert

## Kurzfassung

Dieses Update macht den Stack robuster für produktive Moodle-Solr-Setups:

- Tenant-CLI und Security-Flows sind härter validiert.
- Standalone und SolrCloud werden in CI real getestet.
- Moodle-Ping funktioniert mit verwaltetem Solr-Healthcheck-File.
- Caddy und Nginx können als Proxy-Container im Solr-Netzwerk laufen.
- Die Doku ist kompakter und auf konkrete Betriebswege ausgerichtet.

## Verifikation

- Lokal: Shell-Syntax, Compose-Render, Proxy-Config-Validation und Unit-Tests.
- GitHub Actions: Lint, Security Scan, Standalone Core Tests und SolrCloud Tests für den Healthcheck-Fix grün.

## Hinweis

Bei weiteren Docs-Änderungen zuerst `git pull --ff-only origin feature/3.4.10` ausführen, damit GitHub-Änderungen nicht überschrieben werden.
