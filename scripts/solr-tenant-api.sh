#!/bin/bash
# Copyright (c) 2026 eLeDia GmbH / Bernd Schreistetter (bsc)
# SPDX-License-Identifier: MIT
# Version: v3.1.0
#
# eLeDia Solr Tenant API — helpers: logging, auth, env, naming
# Part of the eLeDia Solr Multi-Tenant Docker Stack.
# Sourced by solr-tenant.sh — do not run directly.


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Solr listens on SOLR_PORT. In SolrCloud mode the official Solr startup script
# starts embedded ZooKeeper on SOLR_PORT + 1000 (8983 -> 9983, 8985 -> 9985).
# Keep ZK_HOST overrideable for external ZooKeeper or unusual deployments.
SOLR_PORT="${SOLR_PORT:-8983}"
SOLR_BASE="http://localhost:${SOLR_PORT}/solr"
if [ -z "${ZK_HOST:-}" ]; then
  case "$SOLR_PORT" in
    ''|*[!0-9]*) ZK_HOST="localhost:9983" ;;
    *) ZK_HOST="localhost:$((SOLR_PORT + 1000))" ;;
  esac
fi
TENANTS_ENV="${TENANTS_ENV:-/opt/solr/tenants.env}"
LOG_FILE="${LOG_FILE:-/var/log/solr/tenant.log}"
ENV_FILE="${ENV_FILE:-/var/solr/data/.env}"
DRY_RUN=0

# SolrCloud mode: set SOLR_MODE=solrcloud in .env
# Standalone (default): Security API + Core Admin API
# SolrCloud: Security API + Collections API + true collection isolation
SOLR_MODE="${SOLR_MODE:-}"

# API Helpers Module — sourced by solr-tenant.sh

# --- _is_cloud_mode ---
_is_cloud_mode() { [ "${SOLR_MODE}" = "solrcloud" ]; }

# Returns the role name for a given tenant.
# Standalone: flat "tenant" role shared by all tenants (Caddy enforces URL isolation).
# SolrCloud:  unique "tenant-<name>" role (Solr enforces collection-level isolation).

# --- _get_tenant_role ---
_get_tenant_role() {
  local name="$1"
  if _is_cloud_mode; then
    printf 'tenant-%s' "$name"
  else
    printf 'tenant'
  fi
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

# --- _log ---
_log() {
  local level="$1"; shift
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] [%-5s] %s\n' "$ts" "$level" "$*" | tee -a "$LOG_FILE" 2>/dev/null || true
}


# --- _log_action ---
_log_action() {
  _log "INFO" "CMD: $*"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# _load_admin_creds: Source Solr admin credentials from the .env file.
# Tries ENV_FILE first, then /.env as fallback.
# Sets ADMIN_USER (from SOLR_ADMIN_USER) and ADMIN_PASS (from SOLR_ADMIN_PASSWORD).
# Args: none
# Returns: nothing; exits with code 1 if SOLR_ADMIN_PASSWORD cannot be resolved

# --- _load_admin_creds ---
_load_admin_creds() {
  local env_file="${ENV_FILE:-/var/solr/data/.env}"
  if [ -f "$env_file" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
  fi
  # Also try host-mounted .env path
  if [ -z "${SOLR_ADMIN_PASSWORD:-}" ] && [ -f "/.env" ]; then
    set -a
    . "/.env"
    set +a
  fi
  ADMIN_USER="${SOLR_ADMIN_USER:-admin}"
  ADMIN_PASS="${SOLR_ADMIN_PASSWORD:-}"
  if [ -z "$ADMIN_PASS" ]; then
    # Try reading directly from security.json via jq (not feasible — hashed)
    _log "ERROR" "SOLR_ADMIN_PASSWORD not set. Set it in .env or export it."
    exit 1
  fi
}

# _solr_api: Send an authenticated HTTP request to the Solr REST API.
# Stores the response body in /tmp/_solr_resp; logs errors to /tmp/_solr_err.
# Args: $1 - HTTP method (GET, POST, etc.), $2 - path (e.g. /admin/cores), $3 - optional JSON body
# Returns: 0 and prints response body on HTTP 200; returns 1 and logs error otherwise

# --- _solr_api ---
_solr_api() {
  local method="${1:-GET}"
  local path="$2"
  local data="${3:-}"
  local http_code

  # Do NOT use -f: it causes curl to exit with code 22 on HTTP>=400, which
  # propagates through $() and triggers set -e before we can log the error.
  if [ -n "$data" ]; then
    http_code="$(curl -s -o /tmp/_solr_resp -w '%{http_code}' \
      -u "${ADMIN_USER}:${ADMIN_PASS}" \
      -X "$method" \
      -H 'Content-Type: application/json' \
      -d "$data" \
      "${SOLR_BASE}${path}" 2>/tmp/_solr_err)" || true
  else
    http_code="$(curl -s -o /tmp/_solr_resp -w '%{http_code}' \
      -u "${ADMIN_USER}:${ADMIN_PASS}" \
      -X "$method" \
      "${SOLR_BASE}${path}" 2>/tmp/_solr_err)" || true
  fi

  if [ "$http_code" != "200" ]; then
    _log "ERROR" "Solr API $method $path returned HTTP ${http_code:-<no response>}"
    _log "ERROR" "Response body: $(head -5 /tmp/_solr_resp 2>/dev/null || true)"
    _log "ERROR" "Curl error: $(cat /tmp/_solr_err 2>/dev/null || true)"
    return 1
  fi
  cat /tmp/_solr_resp 2>/dev/null || true
}

# _gen_password: Generate a random 32-character alphanumeric password.
# Args: none
# Returns: prints 32-character string to stdout

# --- _gen_password ---
_gen_password() {
  openssl rand -base64 36 | tr -d '/+=' | head -c 32
}

# _validate_name: Enforce lowercase-alphanumeric-underscore naming convention.
# Args: $1 - name to validate
# Returns: nothing on success; exits with code 1 if the name is empty or contains invalid chars

# --- _validate_name ---
_validate_name() {
  local name="$1"
  case "$name" in
    *[!a-z0-9_]*)
      printf 'ERROR: Invalid name "%s" — only lowercase letters, digits, underscore allowed.\n' "$name" >&2
      exit 1
      ;;
    '') printf 'ERROR: Name must not be empty.\n' >&2; exit 1 ;;
  esac
}

# _core_exists: Check whether a Solr core (standalone) or collection (SolrCloud) exists.
# Args: $1 - core/collection name
# Returns: 0 if it exists, 1 otherwise

# --- _core_exists ---
_core_exists() {
  local core="$1"
  if _is_cloud_mode; then
    _collection_exists "$core"
  else
    # Solr's STATUS API returns {"status":{"core":{}}} even for non-existent cores.
    # Only an existing core has "instanceDir" in its status object.
    _solr_api GET "/admin/cores?action=STATUS&core=${core}&wt=json" 2>/dev/null \
      | grep -q '"instanceDir"'
  fi
}

# _tenant_exists: Check whether a tenant entry exists in tenants.env.
# Args: $1 - tenant name
# Returns: 0 if TENANT_<name>_CORES line is present, 1 otherwise

# --- _tenant_exists ---
_tenant_exists() {
  local name="$1"
  grep -q "^TENANT_${name}_CORES=" "$TENANTS_ENV" 2>/dev/null
}

# _get_tenant_field: Read a single field value for a tenant from tenants.env.
# Args: $1 - tenant name, $2 - field name (CORES, USER, PASS, ACTIVE)
# Returns: prints the value to stdout; empty output if not found

# --- _get_tenant_field ---
_get_tenant_field() {
  local name="$1" field="$2"
  grep "^TENANT_${name}_${field}=" "$TENANTS_ENV" 2>/dev/null | cut -d= -f2-
}

# _set_tenant_field: Write or update a TENANT_<name>_<field>=<value> line in tenants.env.
# Uses a /tmp tempfile + cat-over to avoid sed's in-place temp file in /opt/solr/ (read-only).
# Creates tenants.env if it does not exist.
# Args: $1 - tenant name, $2 - field name, $3 - value
# Returns: nothing

# --- _set_tenant_field ---
_set_tenant_field() {
  local name="$1" field="$2" value="$3"
  local key="TENANT_${name}_${field}"
  touch "$TENANTS_ENV"
  if grep -q "^${key}=" "$TENANTS_ENV"; then
    local tmp
    tmp="$(mktemp)"
    sed "s|^${key}=.*|${key}=${value}|" "$TENANTS_ENV" > "$tmp"
    cat "$tmp" > "$TENANTS_ENV"
    rm -f "$tmp"
  else
    printf '%s=%s\n' "$key" "$value" >> "$TENANTS_ENV"
  fi
}

# _remove_tenant_lines: Delete all TENANT_<name>_* entries from tenants.env.
# Uses a /tmp tempfile + cat-over to avoid sed's in-place temp file in /opt/solr/ (read-only).
# Args: $1 - tenant name
# Returns: nothing

# --- _remove_tenant_lines ---
_remove_tenant_lines() {
  local name="$1"
  local tmp
  tmp="$(mktemp)"
  sed "/^TENANT_${name}_/d" "$TENANTS_ENV" > "$tmp"
  cat "$tmp" > "$TENANTS_ENV"
  rm -f "$tmp"
}

# _hash_password: Produce a Solr BasicAuthPlugin credential string (unused in current flow —
# credentials are passed as plaintext to the Security API which hashes them server-side).
# Kept for reference: base64(SHA256(SHA256(salt||pass))) + " " + base64(salt)
# Args: $1 - plaintext password
# Returns: prints "<hash_b64> <salt_b64>" to stdout

# --- _hash_password ---
_hash_password() {
  local pass="$1"
  if base64 --help 2>&1 | grep -q 'wrap'; then
    local _b64="base64 -w0"
  else
    local _b64="base64"
  fi
  local sf pf cf h1 h2
  sf="$(mktemp)"; pf="$(mktemp)"; cf="$(mktemp)"; h1="$(mktemp)"; h2="$(mktemp)"
  chmod 600 "$sf" "$pf" "$cf" "$h1" "$h2"
  openssl rand 32 > "$sf"
  printf '%s' "$pass" > "$pf"
  cat "$sf" "$pf" > "$cf"
  openssl dgst -sha256 -binary "$cf" > "$h1"
  openssl dgst -sha256 -binary "$h1" > "$h2"
  local hb sb
  hb="$($_b64 < "$h2" | tr -d '\n\r')"
  sb="$($_b64 < "$sf" | tr -d '\n\r')"
  dd if=/dev/zero of="$pf" bs=1 count="$(wc -c < "$pf")" 2>/dev/null || true
  dd if=/dev/zero of="$cf" bs=1 count="$(wc -c < "$cf")" 2>/dev/null || true
  rm -f "$sf" "$pf" "$cf" "$h1" "$h2"
  printf '%s %s' "$hb" "$sb"
}

# _create_core: Create a Solr core (standalone) or collection (SolrCloud).
# Standalone: uses the Core Admin API with configSet=moodle-tenant.
# SolrCloud:  delegates to _create_collection which uses the Collections API.
# Args: $1 - core/collection name
# Returns: 0 on success or if already exists; 1 on API failure

