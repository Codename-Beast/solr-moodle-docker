# Apache Reverse Proxy Templates

Diese Templates ermöglichen das Aufsetzen mehrerer Solr-Instanzen hinter einem bestehenden Apache Server.

## Architektur

```
Internet → Apache (:443) → Solr Instanzen (127.0.0.1:898x)
             │
             ├─ solr-kunde-a.example.com → :8983
             ├─ solr-kunde-b.example.com → :8984
             └─ solr-kunde-c.example.com → :8985
```

## Quick Start

### 1. SSL-Config einmalig einrichten

```bash
# Kopieren
sudo cp ssl-common.conf /etc/apache2/conf-available/

# Zertifikatspfade anpassen (WICHTIG!)
sudo nano /etc/apache2/conf-available/ssl-common.conf

# Aktivieren
sudo a2enconf ssl-common
```

### 2. Apache-Config generieren

```bash
# Interaktiver Modus
./generate-apache-config.sh

# Oder mit Parametern
./generate-apache-config.sh \
 --instance kunde-a \
 --hostname solr-kunde-a.example.com \
 --port 8983 \
 --email admin@example.com
```

### 3. Config installieren

```bash
# Module aktivieren (falls noch nicht geschehen)
sudo a2enmod ssl proxy proxy_http headers rewrite

# VirtualHost kopieren und aktivieren
sudo cp generated/solr-kunde-a.conf /etc/apache2/sites-available/
sudo a2ensite solr-kunde-a.conf

# Testen und neu laden
sudo apache2ctl configtest
sudo systemctl reload apache2
```

### 4. Solr-Instanz starten

```bash
# In einem separaten Verzeichnis für diese Instanz
cd /opt/solr-kunde-a

# .env anpassen
INSTANCE_NAME=kunde-a
SOLR_PORT=8983
SOLR_HOSTNAME=solr-kunde-a.example.com

# Starten
docker compose up -d
```

## Mehrere Instanzen

Für jede neue Instanz:

1. **Neuen Port wählen** (8983, 8984, 8985, ...)
2. **Apache-Config generieren** mit neuem Hostnamen
3. **Solr in separatem Verzeichnis** mit eigener `.env` starten

Das Generator-Script erkennt automatisch bereits belegte Ports und schlägt den nächsten freien vor.

## Dateien

| Datei | Beschreibung |
|-------|--------------|
| `ssl-common.conf` | Gemeinsame SSL-Einstellungen (Let's Encrypt Zertifikat) |
| `solr-instance.conf.template` | VirtualHost-Template mit Platzhaltern |
| `generate-apache-config.sh` | Generator-Script für neue Configs |
| `generated/` | Generierte Configs (von Git ignoriert) |

## SSL-Zertifikat

Das Template geht von einem **Wildcard-Zertifikat** aus (z.B. `*.example.com`).

Falls ihr einzelne Zertifikate pro Subdomain habt, passt die Pfade in der generierten Config an:

```apache
SSLCertificateFile /etc/letsencrypt/live/solr-kunde-a.example.com/fullchain.pem
SSLCertificateKeyFile /etc/letsencrypt/live/solr-kunde-a.example.com/privkey.pem
```

## Troubleshooting

### Port bereits belegt
```bash
# Prüfen welche Ports belegt sind
ss -tlnp | grep 898
```

### Apache Config-Test schlägt fehl
```bash
# Syntax prüfen
sudo apache2ctl configtest

# Logs prüfen
sudo tail -f /var/log/apache2/error.log
```

### Solr nicht erreichbar
```bash
# Container läuft?
docker compose ps

# Solr antwortet lokal?
curl -u admin:PASSWORT http://127.0.0.1:8983/solr/admin/info/system
```


## solr-helper-pro local UI notes
- `scripts/solr-helper-pro.py` is treated as local-only operator tooling in this workspace.
- Current UI behavior: create button in list header, selection-driven right panel (host+container info + live logs), tenant-capable column in server list, and detail screen with inline config/user/log operations plus Solr runtime/schema summary.
- Theme direction: dark black/orange with stronger borders and accents.
