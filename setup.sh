#!/bin/bash
# Copyright (c) 2026 eLeDia.de / Bernd Schreistetter (bsc)
# Version: v3.4.12

# =========================================
# Solr Multi-Tenant — Interactive Setup
# =========================================
# Idempotent: safe to re-run.
# First run: creates .env, tenants.env, /var/log/eledia/solr-<instance>.log, logrotate, starts Solr.
# Re-run: backs up .env (max 3 generations), updates passwords if requested.

set -euo pipefail

INSTANCE_NAME="${INSTANCE_NAME:-$(grep '^INSTANCE_NAME=' .env 2>/dev/null | cut -d= -f2 | tr -d ' ' || echo solr)}"
INSTANCE_NAME="${INSTANCE_NAME:-solr}"
LOG_ROOT="${LOG_ROOT:-/var/log/eledia}"
LOG_DIR="${LOG_DIR:-${LOG_ROOT}}"
LOG_FILE="${LOG_DIR}/solr-${INSTANCE_NAME}.log"

# _log: Write a timestamped message to stdout and $LOG_FILE.
# Args: $@ - message text
# Returns: nothing
_log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] %s\n' "$ts" "$*"
  printf '[%s] %s\n' "$ts" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

_print_header() {
  printf '\n'
  printf '╔════════════════════════════════════════════════════════════╗\n'
  printf '║  eLeDia Solr Multi-Tenant Setup                           ║\n'
  printf '╚════════════════════════════════════════════════════════════╝\n'
}

_print_step() {
  local nr="$1" title="$2"
  printf '\n▶ Step %s: %s\n' "$nr" "$title"
  _log "Step ${nr}: ${title}"
}

_require_command() {
  local cmd="$1" hint="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    _die "Required command missing: ${cmd}. ${hint}"
  fi
}

# _die: Log an error message and exit with code 1.
# Args: $@ - error description
# Returns: exits with code 1
_die() {
  _log "ERROR: $*"
  exit 1
}

# _gen_password: Generate a random 32-character alphanumeric password.
# Args: none
# Returns: prints 32-character string to stdout
_gen_password() {
  openssl rand -base64 36 | tr -d '/+=' | head -c 32
}

# _env_get: Read a simple KEY=value from .env without evaluating shell code.
# Args: $1 - key name
# Returns: prints value (without surrounding whitespace) or nothing
_env_get() {
  local key="$1"
  grep -E "^${key}=" ".env" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d ' '
}

# _env_set: Set or append a simple KEY=value in .env.
# Args: $1 - key name, $2 - value
# Returns: nothing
_env_set() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  if grep -qE "^${key}=" ".env"; then
    awk -v key="$key" -v value="$value" 'BEGIN { FS=OFS="=" } $1 == key { $0 = key "=" value } { print }' ".env" > "$tmp"
  else
    cp ".env" "$tmp"
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi
  mv "$tmp" ".env"
}

# _prompt_default: Ask for a value with a visible default.
# Args: $1 - label, $2 - default value
# Returns: prints chosen value
_prompt_default() {
  local label="$1" default="$2" value
  if [ ! -t 0 ]; then
    printf '%s' "$default"
    return 0
  fi
  printf '  %s [%s]: ' "$label" "$default" >&2
  read -r value
  printf '%s' "${value:-$default}"
}

# _prompt_choice: Ask until the entered value is in a pipe-separated list.
# Args: $1 - label, $2 - default, $3 - allowed values, e.g. "solrcloud|standalone"
# Returns: prints chosen value
_prompt_choice() {
  local label="$1" default="$2" allowed="$3" value
  while true; do
    value="$(_prompt_default "$label" "$default")"
    case "|${allowed}|" in
      *"|${value}|"*) printf '%s' "$value"; return 0 ;;
    esac
    printf '  Ungültig: %s (erlaubt: %s)\n' "$value" "$allowed" >&2
  done
}

# _prompt_secret: Ask for a secret value; empty keeps/generates depending on caller.
# Args: $1 - label
# Returns: prints entered secret or empty string
_prompt_secret() {
  local label="$1" value
  if [ ! -t 0 ]; then
    printf ''
    return 0
  fi
  printf '  %s: ' "$label" >&2
  read -r -s value
  printf '\n' >&2
  printf '%s' "$value"
}

# _configure_environment_interactive: Configure main .env values via prompts.
# Args: none
# Returns: updates .env in place
_configure_environment_interactive() {
  local value current

  printf '\n=== Basis-Konfiguration ===\n'
  current="$(_env_get INSTANCE_NAME)"; current="${current:-solr}"
  value="$(_prompt_default 'Instance name' "$current")"
  _env_set "INSTANCE_NAME" "$value"
  INSTANCE_NAME="$value"

  current="$(_env_get SOLR_HOSTNAME)"; current="${current:-solr.example.com}"
  value="$(_prompt_default 'Solr hostname' "$current")"
  _env_set "SOLR_HOSTNAME" "$value"

  current="$(_env_get SOLR_BIND)"; current="${current:-127.0.0.1}"
  value="$(_prompt_default 'Bind address' "$current")"
  _env_set "SOLR_BIND" "$value"

  current="$(_env_get SOLR_PORT)"; current="${current:-8983}"
  value="$(_prompt_default 'Host port' "$current")"
  case "$value" in
    ''|*[!0-9]*) _die "Invalid SOLR_PORT: $value" ;;
  esac
  _env_set "SOLR_PORT" "$value"

  current="$(_env_get SOLR_HEAP)"; current="${current:-2g}"
  value="$(_prompt_default 'Solr heap' "$current")"
  _env_set "SOLR_HEAP" "$value"

  current="$(_env_get SOLR_MODE)"; current="${current:-solrcloud}"
  value="$(_prompt_choice 'Solr mode' "$current" 'solrcloud|standalone')"
  _env_set "SOLR_MODE" "$value"

  current="$(_env_get SOLR_ENVIRONMENT)"; current="${current:-prod,label=Production,color=red}"
  value="$(_prompt_default 'Solr environment banner' "$current")"
  _env_set "SOLR_ENVIRONMENT" "$value"
}

# _tenant_exec: Run solr-tenant.sh in the target runtime container.
# Args: $1 - container, remaining args - solr-tenant.sh command
# Returns: command exit code
_tenant_exec() {
  local container="$1"
  shift
  docker exec "$container" /opt/solr/scripts/solr-tenant.sh "$@" 2>&1 | tee -a "$LOG_FILE"
}

# _tenant_management_menu: Interactive tenant day-2 operations.
# Maps to existing helper commands:
#   solr-tenant.sh passwd
#   solr-tenant.sh delete
#   solr-tenant.sh apply
# Args: $1 - container name
# Returns: 0 when the operator exits the menu
_tenant_management_menu() {
  local container="$1" choice tenant cores core password
  if [ ! -t 0 ]; then
    _log "  Tenant management menu skipped (non-interactive stdin)"
    return 0
  fi

  while true; do
    printf '\n=== Tenant-Verwaltung (%s) ===\n' "$container"
    printf '  1) Tenants listen\n'
    printf '  2) Tenant anlegen\n'
    printf '  3) Core/Collection hinzufügen\n'
    printf '  4) Core/Collection entfernen\n'
    printf '  5) Passwort neu setzen\n'
    printf '  6) Tenant deaktivieren\n'
    printf '  7) Tenant reaktivieren\n'
    printf '  8) Apply / aus tenants.env anwenden\n'
    printf '  9) Healthcheck\n'
    printf '  10) Configsets/Suchschema reparieren\n'
    printf '  0) Fertig\n'
    printf '  Auswahl: '
    read -r choice

    case "$choice" in
      1)
        _tenant_exec "$container" list || true
        ;;
      2)
        tenant="$(_prompt_default 'Tenant name' '')"
        cores="$(_prompt_default 'Cores/Collections (kommagetrennt)' '')"
        [ -n "$tenant" ] && [ -n "$cores" ] || { printf '  Tenant und Cores sind Pflicht.\n'; continue; }
        _tenant_exec "$container" create "$tenant" --cores "$cores" || true
        ;;
      3)
        tenant="$(_prompt_default 'Tenant name' '')"
        core="$(_prompt_default 'Core/Collection' '')"
        [ -n "$tenant" ] && [ -n "$core" ] || { printf '  Tenant und Core/Collection sind Pflicht.\n'; continue; }
        _tenant_exec "$container" core-add "$tenant" --core "$core" || true
        ;;
      4)
        tenant="$(_prompt_default 'Tenant name' '')"
        core="$(_prompt_default 'Core/Collection' '')"
        [ -n "$tenant" ] && [ -n "$core" ] || { printf '  Tenant und Core/Collection sind Pflicht.\n'; continue; }
        _tenant_exec "$container" core-remove "$tenant" --core "$core" || true
        ;;
      5)
        tenant="$(_prompt_default 'Tenant name' '')"
        [ -n "$tenant" ] || { printf '  Tenant ist Pflicht.\n'; continue; }
        password="$(_prompt_secret 'Neues Passwort leer=generieren')"
        if [ -n "$password" ]; then
          printf '%s\n' "$password" | docker exec -i "$container" /opt/solr/scripts/solr-tenant.sh passwd "$tenant" --password-stdin 2>&1 | tee -a "$LOG_FILE" || true
        else
          _tenant_exec "$container" passwd "$tenant" || true
        fi
        ;;
      6)
        tenant="$(_prompt_default 'Tenant name' '')"
        [ -n "$tenant" ] || { printf '  Tenant ist Pflicht.\n'; continue; }
        printf '  Tenant %s wirklich deaktivieren? [y/N]: ' "$tenant"
        read -r confirm
        case "$confirm" in y|Y|yes|YES) _tenant_exec "$container" delete "$tenant" --force || true ;; esac
        ;;
      7)
        tenant="$(_prompt_default 'Tenant name' '')"
        [ -n "$tenant" ] || { printf '  Tenant ist Pflicht.\n'; continue; }
        _tenant_exec "$container" enable "$tenant" || true
        ;;
      8)
        _tenant_exec "$container" apply || true
        ;;
      9)
        _tenant_exec "$container" healthcheck || true
        ;;
      10)
        _tenant_exec "$container" config-repair || true
        ;;
      0|q|Q)
        return 0
        ;;
      *)
        printf '  Ungültige Auswahl.\n'
        ;;
    esac
  done
}

# _compose_proxy: Run docker compose against the optional proxy compose file.
# The literal command string is intentionally visible for unit guards:
# docker compose -f docker-compose.proxy.yml --profile
_compose_proxy() {
  local profile="$1"
  shift
  docker compose -f docker-compose.proxy.yml --profile "$profile" "$@" 2>&1 | tee -a "$LOG_FILE"
}

# _configure_proxy_env: Collect proxy values and persist them in .env.
# Args: none
_configure_proxy_env() {
  local value current
  current="$(_env_get PROXY_HOSTNAME)"; current="${current:-$(_env_get SOLR_HOSTNAME)}"; current="${current:-kundendomain.de}"
  value="$(_prompt_default 'Proxy primary hostname' "$current")"
  _env_set "PROXY_HOSTNAME" "$value"

  current="$(_env_get PROXY_SOLR_HOSTNAME)"; current="${current:-solr.${value}}"
  value="$(_prompt_default 'Proxy solr hostname' "$current")"
  _env_set "PROXY_SOLR_HOSTNAME" "$value"

  current="$(_env_get PROXY_HTTP_PORT)"; current="${current:-80}"
  value="$(_prompt_default 'Proxy HTTP port' "$current")"
  case "$value" in ''|*[!0-9]*) _die "Invalid PROXY_HTTP_PORT: $value" ;; esac
  _env_set "PROXY_HTTP_PORT" "$value"

  current="$(_env_get PROXY_HTTPS_PORT)"; current="${current:-443}"
  value="$(_prompt_default 'Proxy HTTPS port' "$current")"
  case "$value" in ''|*[!0-9]*) _die "Invalid PROXY_HTTPS_PORT: $value" ;; esac
  _env_set "PROXY_HTTPS_PORT" "$value"

  current="$(_env_get PROXY_ADMIN_EMAIL)"; current="${current:-admin@example.com}"
  value="$(_prompt_default 'Proxy admin email' "$current")"
  _env_set "PROXY_ADMIN_EMAIL" "$value"
}

# _proxy_management_menu: Configure/start optional proxy paths.
# Args: $1 - Solr runtime container name
_proxy_management_menu() {
  local container="$1" choice hostname port instance
  if [ ! -t 0 ]; then
    _log "  Proxy management menu skipped (non-interactive stdin)"
    return 0
  fi

  while true; do
    printf '\n=== Proxy-Verwaltung ===\n'
    printf '  1) Proxy-Werte in .env setzen\n'
    printf '  2) Caddy Proxy-Container starten/aktualisieren\n'
    printf '  3) Nginx Proxy-Container starten/aktualisieren\n'
    printf '  4) Proxy-Container Status\n'
    printf '  5) Proxy-Container stoppen\n'
    printf '  6) Caddyfile Tenant-Snippet aus Runtime erzeugen\n'
    printf '  7) Host-Nginx Config generieren\n'
    printf '  8) Host-Apache Config generieren\n'
    printf '  0) Zurück\n'
    printf '  Auswahl: '
    read -r choice

    case "$choice" in
      1)
        _configure_proxy_env
        ;;
      2)
        _configure_proxy_env
        _compose_proxy caddy up -d
        ;;
      3)
        _configure_proxy_env
        _compose_proxy nginx up -d
        ;;
      4)
        docker compose -f docker-compose.proxy.yml ps 2>&1 | tee -a "$LOG_FILE" || true
        ;;
      5)
        docker compose -f docker-compose.proxy.yml down 2>&1 | tee -a "$LOG_FILE" || true
        ;;
      6)
        hostname="$(_prompt_default 'Domain für Tenant-Subdomains' "$(_env_get PROXY_HOSTNAME)")"
        [ -n "$hostname" ] || { printf '  Domain ist Pflicht.\n'; continue; }
        _tenant_exec "$container" caddy-config --domain "$hostname" || true
        ;;
      7)
        instance="$(_env_get INSTANCE_NAME)"; instance="${instance:-solr}"
        hostname="$(_prompt_default 'Public hostname' "$(_env_get PROXY_SOLR_HOSTNAME)")"
        port="$(_prompt_default 'Solr host port' "$(_env_get SOLR_PORT)")"
        [ -n "$hostname" ] && [ -n "$port" ] || { printf '  Hostname und Port sind Pflicht.\n'; continue; }
        nginx/generate-nginx-config.sh --instance "$instance" --hostname "$hostname" --port "$port" 2>&1 | tee -a "$LOG_FILE" || true
        ;;
      8)
        instance="$(_env_get INSTANCE_NAME)"; instance="${instance:-solr}"
        hostname="$(_prompt_default 'Public hostname' "$(_env_get PROXY_SOLR_HOSTNAME)")"
        port="$(_prompt_default 'Solr host port' "$(_env_get SOLR_PORT)")"
        [ -n "$hostname" ] && [ -n "$port" ] || { printf '  Hostname und Port sind Pflicht.\n'; continue; }
        apache/generate-apache-config.sh --instance "$instance" --hostname "$hostname" --port "$port" 2>&1 | tee -a "$LOG_FILE" || true
        ;;
      0|q|Q)
        return 0
        ;;
      *)
        printf '  Ungültige Auswahl.\n'
        ;;
    esac
  done
}

_existing_stack_available() {
  local instance container
  instance="$(_env_get INSTANCE_NAME)"
  instance="${instance:-${INSTANCE_NAME:-solr}}"
  container="${instance}-solr"
  [ -f ".env" ] || return 1
  docker inspect "$container" >/dev/null 2>&1 || return 1
  printf '%s' "$container"
}

# _management_menu: Main runtime-management menu for existing installations.
# Works against the running Solr runtime container and delegates state changes to solr-tenant.sh.
_management_menu() {
  local container="$1" choice
  if [ ! -t 0 ]; then
    _log "  Runtime management skipped (non-interactive stdin)"
    return 0
  fi

  printf '\nBestehende Installation erkannt: %s\n' "$container"
  while true; do
    printf '\n=== Runtime-Management (%s) ===\n' "$container"
    printf '  1) Status / Healthcheck\n'
    printf '  2) Tenant-Verwaltung\n'
    printf '  3) Runtime aus tenants.env anwenden (apply)\n'
    printf '  4) Runtime mit .env + tenants.env synchronisieren (sync-sot)\n'
    printf '  5) Drift erkennen\n'
    printf '  6) Drift beheben\n'
    printf '  7) Runtime-Wahrheit anzeigen\n'
    printf '  8) Proxy-Verwaltung\n'
    printf '  9) Stack neu starten\n'
    printf '  10) Logs anzeigen\n'
    printf '  0) Beenden\n'
    printf '  Auswahl: '
    read -r choice

    case "$choice" in
      1)
        _tenant_exec "$container" healthcheck || true
        docker compose ps 2>&1 | tee -a "$LOG_FILE" || true
        ;;
      2)
        _tenant_management_menu "$container"
        ;;
      3)
        _tenant_exec "$container" apply || true
        ;;
      4)
        # solr-tenant.sh sync-sot keeps runtime users/permissions aligned with .env + tenants.env.
        _tenant_exec "$container" sync-sot || true
        ;;
      5)
        _tenant_exec "$container" drift-detect || true
        ;;
      6)
        # solr-tenant.sh drift-remediate delegates remediation to sync-sot in the runtime helper.
        _tenant_exec "$container" drift-remediate || true
        ;;
      7)
        _tenant_exec "$container" runtime-truth || true
        ;;
      8)
        _proxy_management_menu "$container"
        ;;
      9)
        docker compose restart solr 2>&1 | tee -a "$LOG_FILE" || true
        ;;
      10)
        docker compose logs --tail=120 --no-color 2>&1 | tee -a "$LOG_FILE" || true
        ;;
      0|q|Q)
        return 0
        ;;
      *)
        printf '  Ungültige Auswahl.\n'
        ;;
    esac
  done
}

# _setup_tenant_exists: Check if a tenant already exists in the running Solr container.
# Args: $1 - container name, $2 - tenant name
# Returns: 0 when tenant exists, 1 otherwise
_setup_tenant_exists() {
  local container="$1" tenant="$2"
  docker exec "$container" /opt/solr/scripts/solr-tenant.sh info "$tenant" >/dev/null 2>&1
}

# _setup_provision_tenants: Create or extend tenants from a compact setup spec.
# Format: tenant_a:core1,core2;tenant_b:core3
# Reuses the in-container solr-tenant.sh helper; in SolrCloud the same core names
# are created as collections by the runtime helper.
# Args: $1 - container name, $2 - tenant spec
# Returns: non-zero if any tenant/core provisioning command fails
_setup_provision_tenants() {
  local container="$1" tenant_spec="$2"
  local entry tenant cores core
  local -a tenant_entries core_entries

  [ -z "$tenant_spec" ] && return 0

  IFS=';' read -ra tenant_entries <<< "$tenant_spec"
  for entry in "${tenant_entries[@]}"; do
    entry="$(printf '%s' "$entry" | tr -d '[:space:]')"
    [ -z "$entry" ] && continue

    tenant="${entry%%:*}"
    cores="${entry#*:}"
    if [ -z "$tenant" ] || [ "$tenant" = "$cores" ] || [ -z "$cores" ]; then
      _die "Invalid SETUP_TENANTS entry '${entry}'. Use tenant:core1,core2;other:core3"
    fi

    if _setup_tenant_exists "$container" "$tenant"; then
      _log "  Tenant '${tenant}' already exists — adding missing cores/collections"
      IFS=',' read -ra core_entries <<< "$cores"
      for core in "${core_entries[@]}"; do
        core="$(printf '%s' "$core" | tr -d '[:space:]')"
        [ -z "$core" ] && continue
        docker exec "$container" /opt/solr/scripts/solr-tenant.sh core-add "$tenant" --core "$core" 2>&1 | tee -a "$LOG_FILE"
      done
    else
      _log "  Creating tenant '${tenant}' with cores/collections '${cores}'"
      docker exec "$container" /opt/solr/scripts/solr-tenant.sh create "$tenant" --cores "$cores" 2>&1 | tee -a "$LOG_FILE"
    fi
  done
}

# Allow unit tests to source setup.sh without starting the installer.
if [ "${SETUP_LIBRARY_ONLY:-0}" = "1" ]; then
  # shellcheck disable=SC2317  # exit branch is reachable when setup.sh is executed, not sourced.
  return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if [ ! -f "docker-compose.yml" ]; then
  printf 'ERROR: Run setup.sh from the repo root directory.\n' >&2
  exit 1
fi

_print_header
_require_command docker "Install Docker Engine with Compose v2."
_require_command openssl "OpenSSL is required to generate secure passwords."
if ! docker compose version >/dev/null 2>&1; then
  printf 'ERROR: docker compose v2 is required.\n' >&2
  exit 1
fi

# Setup log file early (before _log works)
mkdir -p "$LOG_DIR" 2>/dev/null || {
  printf 'WARNING: Cannot create %s — continuing without file log\n' "$LOG_DIR" >&2
  LOG_FILE="/dev/null"
}
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"

_log "=== setup.sh started ==="

EXISTING_CONTAINER=""
if [ "${SETUP_FORCE_INSTALL:-0}" != "1" ]; then
  EXISTING_CONTAINER="$(_existing_stack_available || true)"
fi
if [ -n "$EXISTING_CONTAINER" ] && [ -t 0 ]; then
  _management_menu "$EXISTING_CONTAINER"
  exit 0
fi

# Kein vorhandener Container gefunden: normale Installationsroutine.

# ---------------------------------------------------------------------------
# Step 1: .env setup
# ---------------------------------------------------------------------------
_print_step "1" "Environment configuration"

FIRST_INSTALL=0
if [ ! -f ".env" ]; then
  _log "  First installation — no .env found"
  FIRST_INSTALL=1
  if [ ! -f ".env.example" ]; then
    _die ".env.example not found"
  fi
  cp ".env.example" ".env"
else
  _log "  Existing .env found"
  # Rotate backups: .env.backup.3 <- .env.backup.2 <- .env.backup.1 <- .env
  [ -f ".env.backup.2" ] && cp ".env.backup.2" ".env.backup.3"
  [ -f ".env.backup.1" ] && cp ".env.backup.1" ".env.backup.2"
  cp ".env" ".env.backup.1"
  _log "  Backup: .env -> .env.backup.1"
fi

_configure_environment_interactive
LOG_FILE="${LOG_DIR}/solr-${INSTANCE_NAME}.log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"

# Read or generate admin password
printf '\n'
printf '=== Solr Admin Password ===\n'
if [ "$FIRST_INSTALL" = "1" ]; then
  printf '  Leave empty to auto-generate (recommended for first install).\n'
else
  printf '  Leave empty to keep the existing password from .env.\n'
fi
INPUT_ADMIN_PASS="$(_prompt_secret 'Admin password')"

if [ -z "$INPUT_ADMIN_PASS" ]; then
  ADMIN_PASS="$(_env_get SOLR_ADMIN_PASSWORD)"
  if [ "$FIRST_INSTALL" = "1" ] || [ -z "$ADMIN_PASS" ] || echo "$ADMIN_PASS" | grep -qi "CHANGE_ME"; then
    ADMIN_PASS="$(_gen_password)"
    _log "  Admin password: auto-generated"
  else
    _log "  Admin password: preserved from existing .env"
  fi
else
  ADMIN_PASS="$INPUT_ADMIN_PASS"
  _log "  Admin password: set manually"
fi

printf '=== Solr Support Password ===\n'
if [ "$FIRST_INSTALL" = "1" ]; then
  printf '  Leave empty to auto-generate.\n'
else
  printf '  Leave empty to keep the existing password from .env.\n'
fi
INPUT_SUPPORT_PASS="$(_prompt_secret 'Support password')"

if [ -z "$INPUT_SUPPORT_PASS" ]; then
  SUPPORT_PASS="$(_env_get SOLR_SUPPORT_PASSWORD)"
  if [ "$FIRST_INSTALL" = "1" ] || [ -z "$SUPPORT_PASS" ] || echo "$SUPPORT_PASS" | grep -qi "CHANGE_ME"; then
    SUPPORT_PASS="$(_gen_password)"
    _log "  Support password: auto-generated"
  else
    _log "  Support password: preserved from existing .env"
  fi
else
  SUPPORT_PASS="$INPUT_SUPPORT_PASS"
  _log "  Support password: set manually"
fi

_env_set "SOLR_ADMIN_PASSWORD" "$ADMIN_PASS"
_env_set "SOLR_SUPPORT_PASSWORD" "$SUPPORT_PASS"
chmod 600 ".env"
if [ "$FIRST_INSTALL" = "1" ]; then
  _log "  .env created from .env.example with generated passwords"
else
  _log "  .env preserved; password fields updated only when requested"
fi

# ---------------------------------------------------------------------------
# Step 2: tenants.env
# ---------------------------------------------------------------------------
_print_step "2" "Tenant source file"

_ensure_tenants_env_permissions() {
  local path="${1:-tenants.env}"

  # Preferred: make the Solr runtime UID the owner and keep the file non-world-writable.
  if chown 8983:8983 "$path" 2>/dev/null; then
    chmod 660 "$path"
    _log "  ${path}: owner set to 8983:8983, mode 660"
    return 0
  fi

  # Non-root installs cannot chown arbitrary host files. Use a POSIX ACL when available
  # so UID 8983 can still read/write the bind-mounted file without opening it to everyone.
  if command -v setfacl >/dev/null 2>&1 && chmod 640 "$path" 2>/dev/null && setfacl -m u:8983:rw,m::rw "$path" 2>/dev/null; then
    _log "  ${path}: granted rw ACL for UID 8983"
    return 0
  fi

  # Last fallback for filesystems without usable chown/ACL. This is less strict, but keeps
  # setup functional and is still better than a Solr startup failure.
  chmod 666 "$path"
  _log "  WARNING: ${path}: could not chown or set ACL for UID 8983; using mode 666 fallback"
}

if [ ! -f "tenants.env" ]; then
  touch "tenants.env"
  _ensure_tenants_env_permissions "tenants.env"
  _log "  Created empty tenants.env"
else
  _ensure_tenants_env_permissions "tenants.env"
  _log "  tenants.env already exists — preserving content, enforcing UID 8983 access"
fi

# ---------------------------------------------------------------------------
# Step 3: Logging
# ---------------------------------------------------------------------------
_print_step "3" "Log directory"

mkdir -p "$LOG_DIR"
# Solr container UID 8983 can write native logs; docker group can read them on host.
chown 8983:docker "$LOG_DIR" 2>/dev/null || true
if [ "$(stat -c '%G' "$LOG_DIR" 2>/dev/null)" = "docker" ]; then
  chmod 750 "$LOG_DIR" 2>/dev/null || true
else
  chmod 755 "$LOG_DIR" 2>/dev/null || true
fi
_log "  Log directory: $LOG_DIR"

# Add the user who triggered the install to docker group so they can read logs without sudo
INSTALLING_USER="${SUDO_USER:-}"
if [ -n "$INSTALLING_USER" ] && [ "$INSTALLING_USER" != "root" ]; then
  if id "$INSTALLING_USER" >/dev/null 2>&1; then
    if usermod -aG docker "$INSTALLING_USER" 2>/dev/null; then
      _log "  Added '$INSTALLING_USER' to docker group (logout/login to apply)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Step 4: Logrotate
# ---------------------------------------------------------------------------
_print_step "4" "Logrotate"

LOGROTATE_FILE="/etc/logrotate.d/solr-eledia"
LOGROTATE_GROUP="root"
getent group docker >/dev/null 2>&1 && LOGROTATE_GROUP="docker"
if [ -w "/etc/logrotate.d" ] || [ "$(id -u)" = "0" ]; then
  cat > "$LOGROTATE_FILE" <<EOF
${LOG_ROOT}/solr-*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
    create 640 root ${LOGROTATE_GROUP}
}
EOF
  _log "  Logrotate config written to $LOGROTATE_FILE (group=${LOGROTATE_GROUP})"
else
  _log "  WARNING: Cannot write to /etc/logrotate.d (run as root for logrotate setup)"
fi

# ---------------------------------------------------------------------------
# Step 5: Build runtime images
# ---------------------------------------------------------------------------
_print_step "5" "Build runtime images"

if ! docker compose build eLeDia-solr-init solr 2>&1 | tee -a "$LOG_FILE"; then
  _die "docker compose build eLeDia-solr-init solr failed"
fi

# ---------------------------------------------------------------------------
# Step 6: Start stack
# ---------------------------------------------------------------------------
_print_step "6" "Start Solr"

docker compose up -d 2>&1 | tee -a "$LOG_FILE"

# Wait for healthy (max 180s)
CONTAINER_NAME="${INSTANCE_NAME}-solr"
_log "  Waiting for ${CONTAINER_NAME} to become healthy (max 180s)..."
ELAPSED=0
HEALTHY=0
while [ "$ELAPSED" -lt 180 ]; do
  STATUS="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || echo 'missing')"
  printf '  [%3ss] %s\n' "$ELAPSED" "$STATUS"
  if [ "$STATUS" = "healthy" ]; then
    HEALTHY=1
    break
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

if [ "$HEALTHY" = "0" ]; then
  _log "ERROR: Solr did not become healthy within 180 seconds"
  _log "  Container logs:"
  docker compose logs --tail=50 2>&1 | tee -a "$LOG_FILE"

  if [ "$FIRST_INSTALL" = "0" ] && [ -f ".env.backup.1" ]; then
    _log "  Rolling back .env from backup"
    cp ".env.backup.1" ".env"
    docker compose down 2>&1 | tee -a "$LOG_FILE" || true
  else
    docker compose down 2>&1 | tee -a "$LOG_FILE" || true
  fi
  _die "Setup failed. Check $LOG_FILE for details."
fi

# ---------------------------------------------------------------------------
# Step 7: Optional tenant provisioning
# ---------------------------------------------------------------------------
_print_step "7" "Initial tenants"

SETUP_TENANTS="${SETUP_TENANTS:-}"
if [ -z "$SETUP_TENANTS" ] && [ -t 0 ]; then
  printf '\n'
  printf 'Optionale Tenant-Anlage direkt über das Setup.\n'
  printf 'Format: tenant_a:core1,core2;tenant_b:core3\n'
  printf 'In SolrCloud werden diese Core-Namen als Collections angelegt. Leer lassen zum Überspringen.\n'
  printf '  Tenants: '
  read -r SETUP_TENANTS
fi

if [ -n "$SETUP_TENANTS" ]; then
  _setup_provision_tenants "$CONTAINER_NAME" "$SETUP_TENANTS"
else
  _log "  No initial tenants requested"
fi

if [ -t 0 ]; then
  printf '  Tenant-Verwaltung jetzt öffnen? [y/N]: '
  read -r OPEN_TENANT_MENU
  case "$OPEN_TENANT_MENU" in
    y|Y|yes|YES) _tenant_management_menu "$CONTAINER_NAME" ;;
  esac
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
INSTANCE_NAME="$(grep '^INSTANCE_NAME=' .env | cut -d= -f2 | tr -d ' ')"
INSTANCE_NAME="${INSTANCE_NAME:-solr}"
SOLR_PORT="$(grep '^SOLR_PORT=' .env | cut -d= -f2 | tr -d ' ')"
SOLR_PORT="${SOLR_PORT:-8983}"

_log "=== Setup completed successfully ==="
_log "Collecting setup-time container logs into ${LOG_FILE}"
docker compose logs --no-color >> "$LOG_FILE" 2>&1 || true


printf '\n'
printf '╔════════════════════════════════════════════════════════════╗\n'
printf '║  Solr Multi-Tenant — Setup Complete                       ║\n'
printf '╠════════════════════════════════════════════════════════════╣\n'
printf '║  Instance:   %-44s║\n' "$INSTANCE_NAME"
printf '║  Container:  %-44s║\n' "$CONTAINER_NAME"
printf '║  Solr URL:   http://127.0.0.1:%-28s║\n' "${SOLR_PORT}/solr"
printf '║  Logs:       %-44s║\n' "$LOG_DIR/"
printf '╚════════════════════════════════════════════════════════════╝\n'
printf '\n'
printf 'Next commands:\n'
printf '  Healthcheck:\n'
printf '    docker exec %s /opt/solr/scripts/solr-tenant.sh healthcheck\n' "$CONTAINER_NAME"
printf '  Tenant anlegen:\n'
printf '    docker exec %s /opt/solr/scripts/solr-tenant.sh create <name> --cores <core1>[,<core2>]\n' "$CONTAINER_NAME"
printf '  Tenants aus Runtime-API lesen:\n'
printf '    docker exec %s /opt/solr/scripts/solr-tenant.sh runtime-truth\n' "$CONTAINER_NAME"
printf '  Tenants listen:\n'
printf '    docker exec %s /opt/solr/scripts/solr-tenant.sh list\n' "$CONTAINER_NAME"
printf '\n'
printf 'Files:\n'
printf '  Admin credentials:  .env\n'
printf '  Tenant credentials: tenants.env\n'
printf '\n'
