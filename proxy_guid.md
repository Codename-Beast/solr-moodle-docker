# 🌐 Proxy Guide für Solr & Moodle

Kurzguide für Reverse-Proxy-Setups vor dem Solr/Moodle-Stack.

> ✅ **Caddy ist hier bereits verifiziert.**
> 
> Die Solr-Ansible-Rolle richtet aktuell nur **Apache** und **Caddy** ein.
> **Nginx** ist hier als Referenz dokumentiert, aber nicht durch die Rolle provisioniert.

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
| **Nginx** | 🟡 manuell | Als Referenz unten, aber nicht durch die Rolle gesetzt |

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
  reverse_proxy @solr solr:8983 {
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

- Für Solr immer die echten Upstream-Ports verwenden
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

  ProxyPass        /solr/  http://solr:8983/solr/
  ProxyPassReverse /solr/  http://solr:8983/solr/

  ProxyPass        /moodle/ http://moodle:80/moodle/
  ProxyPassReverse /moodle/ http://moodle:80/moodle/
</VirtualHost>
```

### Hinweise

- `ProxyPreserveHost On` ist hier wichtig
- `X-Forwarded-Proto` muss korrekt gesetzt sein, sonst geraten Redirects und Session-Cookies durcheinander
- In SolrCloud darf der Proxy nicht „intelligent“ umschreiben – einfach weiterleiten

---

## 🧩 Nginx

### Status

Nginx ist als Vorlage sinnvoll, wird aber aktuell **nicht** von der Ansible-Rolle provisioniert.

### Beispiel

```nginx
server {
  listen 443 ssl http2;
  server_name solr.example.org;

  ssl_certificate     /etc/ssl/certs/fullchain.pem;
  ssl_certificate_key /etc/ssl/private/privkey.pem;

  location /solr/ {
    proxy_pass http://solr:8983/solr/;
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
3. **Nginx** nur dann, wenn du es bewusst manuell pflegen willst

---

## 📝 Merksatz

**Caddy funktioniert bereits.**
Die Solr-Ansible-Rolle automatisiert aktuell nur **Apache** und **Caddy** – **Nginx** bleibt eine manuelle Referenz.
