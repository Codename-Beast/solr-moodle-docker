# 🌐 Proxy Guide für Solr & Moodle

Kurzguide für Reverse-Proxy-Setups vor dem Solr/Moodle-Stack.

> ✅ **Caddy ist hier bereits verifiziert.**
> 
> Caddy, Apache und Nginx sind dokumentiert. Apache und Nginx haben Generatoren; Caddy kann über `solr-tenant.sh caddy-config` erzeugt werden.

---

## 🧭 Ziel

Dieses Dokument zeigt, wie der Stack hinter einem Reverse Proxy betrieben wird – sowohl für:

- **Standalone**-Solr
- **SolrCloud**-Solr

Die Proxy-Schicht soll:

- TLS terminieren
- saubere Host-/Forwarded-Header setzen
- Solr/Pfad-Routing stabil halten
- Moodle und Solr konsistent erreichbar machen

---

## 📦 Unterstützte Proxies

| Proxy | Status | Hinweis |
|---|---:|---|
| **Caddy** | ✅ empfohlen | Funktioniert bereits, einfache Konfiguration, gute Defaults |
| **Apache** | ✅ unterstützt | Wird von der Solr-Ansible-Rolle mit eingerichtet |
| **Nginx** | ✅ unterstützt | Generator unter `nginx/generate-nginx-config.sh` |

---

## 🏗️ Betriebsarten

### 1) Standalone

- Solr läuft als einzelne Instanz
- Proxy zeigt direkt auf den Solr-HTTP-Port
- Pfade sind simpel, z. B. `/solr/`

### 2) SolrCloud

- Solr läuft als Cluster
- Proxy leitet weiterhin HTTP-Anfragen an den Solr-Frontend-Port weiter
- Collections und tenant-aware Pfade bleiben unverändert
- Wichtig: Header und Pfad-Regeln dürfen nicht „korrigiert“ werden, sonst brechen Auth/ACLs oder Collection-Routing


---

## 🔌 Upstream wählen

Der externe Zugriff auf Solr/Moodle sollte über HTTPS laufen. TLS endet am Reverse Proxy.
Der interne Upstream vom Proxy zu Solr darf normales HTTP bleiben.

Welche Backend-Adresse richtig ist, hängt davon ab, wo der Proxy läuft:

| Proxy läuft ... | Solr-Upstream | Wann verwenden |
|---|---|---|
| direkt auf dem Host | `http://127.0.0.1:${SOLR_PORT}/solr/` | Standard, wenn Nginx/Apache/Caddy auf dem Docker-Host läuft |
| als Container im selben Docker-Netzwerk | `http://<containername>:<solr-port>/solr/` | wenn der Proxy-Container am `solr-network` hängt |
| als Container mit Alias | `http://solr:<solr-port>/solr/` | nur wenn der Alias `solr` explizit im Docker-Netzwerk existiert |

`SOLR_BIND=127.0.0.1` schützt nur den Host-Port. Ein Proxy-Container kann diesen
Host-Loopback nicht direkt nutzen; er braucht dann den Docker-DNS-Namen oder einen
Netzwerk-Alias. In diesem Compose-Stack ist der Solr-Containername standardmäßig
`${INSTANCE_NAME:-solr}-solr`, also z. B. `solr-solr` oder `prod-solr`.

Ein Proxy-Container sieht Solr nur, wenn er am selben Docker-Netzwerk hängt:

```bash
docker network connect solr-network nginx-proxy
```

Oder in einer eigenen Compose-Datei:

```yaml
services:
  nginx:
    networks:
      - solr_network

networks:
  solr_network:
    external: true
    name: solr-network
```

Bei anderem `INSTANCE_NAME` heißt das Netzwerk entsprechend `${INSTANCE_NAME}-network`.

---

## 🧩 Caddy

### Warum Caddy?

- schnelle, klare Konfiguration
- automatische TLS-Logik möglich
- für dieses Projekt bereits erfolgreich im Einsatz

### Beispiel

```caddyfile
solr.example.org {
  encode zstd gzip

  @solr path /solr/*
  reverse_proxy @solr 127.0.0.1:8983 {
    header_up Host {host}
    header_up X-Forwarded-Host {host}
    header_up X-Forwarded-Proto {scheme}
    header_up X-Forwarded-For {remote_host}
  }

  @moodle path /moodle/*
  reverse_proxy @moodle moodle:80 {
    header_up Host {host}
    header_up X-Forwarded-Host {host}
    header_up X-Forwarded-Proto {scheme}
    header_up X-Forwarded-For {remote_host}
  }
}
```

### Hinweise

- Für Solr immer die passende Upstream-Adresse verwenden: Host-Proxy `127.0.0.1:${SOLR_PORT}`, Container-Proxy Docker-DNS/Netzwerk-Alias plus interner Solr-Port.
- Keine Pfad-Rewrites einbauen, wenn der Backend-Pfad bereits korrekt ist
- Wenn mehrere Services auf einer Domain liegen, sauber per Path-Matcher trennen

---

## 🧩 Apache

### Warum Apache?

- im Bestand oft vorhanden
- solide Reverse-Proxy-Funktionen
- durch die Solr-Ansible-Rolle aktuell direkt konfigurierbar

### Beispiel

```apache
<VirtualHost *:443>
  ServerName solr.example.org

  SSLEngine on
  SSLProxyEngine on

  ProxyPreserveHost On
  RequestHeader set X-Forwarded-Proto "https"
  RequestHeader set X-Forwarded-Host "%{Host}i"

  ProxyPass        /solr/  http://127.0.0.1:8983/solr/
  ProxyPassReverse /solr/  http://127.0.0.1:8983/solr/

  ProxyPass        /moodle/ http://moodle:80/moodle/
  ProxyPassReverse /moodle/ http://moodle:80/moodle/
</VirtualHost>
```

### Hinweise

- `ProxyPreserveHost On` ist hier wichtig
- Wenn Apache als Container läuft, `127.0.0.1` durch den Docker-DNS-Namen ersetzen, z. B. `${INSTANCE_NAME}-solr`, oder einen expliziten Alias wie `solr`.
- `X-Forwarded-Proto` muss korrekt gesetzt sein, sonst geraten Redirects und Session-Cookies durcheinander
- In SolrCloud darf der Proxy nicht „intelligent“ umschreiben – einfach weiterleiten

---

## 🧩 Nginx

### Status

Nginx wird über `nginx/generate-nginx-config.sh` als Datei generiert. Die erzeugte Datei enthält zwei klare Upstream-Varianten: Host-Port oder Docker-Netzwerk.

### Beispiel

```nginx
server {
  listen 443 ssl http2;
  server_name solr.example.org;

  ssl_certificate     /etc/ssl/certs/fullchain.pem;
  ssl_certificate_key /etc/ssl/private/privkey.pem;

  location /solr/ {
    proxy_pass http://127.0.0.1:8983/solr/;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  }

  location /moodle/ {
    proxy_pass http://moodle:80/moodle/;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  }
}
```

### Hinweise

- `proxy_pass` mit Trailing Slash sauber halten
- Wenn Nginx als Container läuft, `127.0.0.1` durch den Docker-DNS-Namen ersetzen, z. B. `${INSTANCE_NAME}-solr`, oder einen expliziten Alias wie `solr`.
- gleiche Header-Regeln wie bei Caddy/Apache verwenden
- wenn die Ansible-Rolle eingesetzt wird, ist Nginx hier nur Doku, kein Ziel der Automatisierung

---

## 🤖 Was die Solr-Ansible-Rolle aktuell macht

Die Rolle deckt aktuell folgende Proxy-Varianten ab:

- **Apache**
- **Caddy**

Das heißt konkret:

- Caddy ist bereits als funktionierender Zielweg dokumentiert
- Apache ist als klassischer Zielweg vorgesehen
- Nginx musst du aktuell manuell konfigurieren

---

## 🧪 Checkliste

- [ ] Reverse Proxy termininiert TLS
- [ ] `Host` und `X-Forwarded-*` werden korrekt gesetzt
- [ ] Solr ist unter dem erwarteten Pfad erreichbar
- [ ] Moodle-Redirects funktionieren hinter dem Proxy
- [ ] SolrCloud-Requests landen ohne zusätzliche Pfad-Manipulation beim Backend
- [ ] Apache/Caddy wurden bevorzugt, wenn die Ansible-Rolle die Konfiguration setzen soll

---

## ✅ Empfehlung

Wenn du einen robusten und schnellen Weg willst:

1. **Caddy** nehmen, wenn du maximale Einfachheit willst
2. **Apache**, wenn du die Ansible-Rolle direkt nutzen willst
3. **Nginx**, wenn Nginx der bevorzugte Standard auf dem Zielsystem ist

---

## 📝 Merksatz

**Caddy funktioniert bereits.**
Nach außen HTTPS, intern HTTP zum Solr-Upstream. Pro Installation genau eine Upstream-Variante aktivieren: Host-Port oder Docker-Netzwerk mit passendem Containername und Port.
