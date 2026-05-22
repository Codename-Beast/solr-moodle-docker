#!/bin/bash
# =========================================
# Solr Multi-Tenant CLI
# Developer: BSC Bernd Schreistetter
# Company: Eledia.de
# Version: v3.0.1
# =========================================
# Manages Solr tenants (Moodle instances) via Solr Security API.
# Must run inside the solr container:
#   docker exec <container> /opt/solr/scripts/solr-tenant.sh <command>
#
# All write actions update tenants.env AND call the Security API immediately.
# On container restart, powerinit.sh rebuilds security.json from tenants.env.

set -euo pipefail

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

_is_cloud_mode() { [ "${SOLR_MODE}" = "solrcloud" ]; }

# Returns the role name for a given tenant.
# Standalone: flat "tenant" role shared by all tenants (Caddy enforces URL isolation).
# SolrCloud:  unique "tenant-<name>" role (Solr enforces collection-level isolation).
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
_log() {
  local level="$1"; shift
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] [%-5s] %s\n' "$ts" "$level" "$*" | tee -a "$LOG_FILE" 2>/dev/null || true
}

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
_gen_password() {
  openssl rand -base64 36 | tr -d '/+=' | head -c 32
}

# _validate_name: Enforce lowercase-alphanumeric-underscore naming convention.
# Args: $1 - name to validate
# Returns: nothing on success; exits with code 1 if the name is empty or contains invalid chars
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
_tenant_exists() {
  local name="$1"
  grep -q "^TENANT_${name}_CORES=" "$TENANTS_ENV" 2>/dev/null
}

# _get_tenant_field: Read a single field value for a tenant from tenants.env.
# Args: $1 - tenant name, $2 - field name (CORES, USER, PASS, ACTIVE)
# Returns: prints the value to stdout; empty output if not found
_get_tenant_field() {
  local name="$1" field="$2"
  grep "^TENANT_${name}_${field}=" "$TENANTS_ENV" 2>/dev/null | cut -d= -f2-
}

# _set_tenant_field: Write or update a TENANT_<name>_<field>=<value> line in tenants.env.
# Uses a /tmp tempfile + cat-over to avoid sed's in-place temp file in /opt/solr/ (read-only).
# Creates tenants.env if it does not exist.
# Args: $1 - tenant name, $2 - field name, $3 - value
# Returns: nothing
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
_create_core() {
  local core="$1"
  if _is_cloud_mode; then
    _create_collection "$core"
  else
    if _core_exists "$core"; then
      _log "INFO" "Core '$core' already exists"
      return 0
    fi
    _log "INFO" "Creating core '$core'"
    if [ "$DRY_RUN" = "1" ]; then
      printf '[DRY-RUN] Would create core: %s\n' "$core"
      return 0
    fi
    _solr_api GET "/admin/cores?action=CREATE&name=${core}&configSet=moodle-tenant&wt=json" > /dev/null
    _log "INFO" "Core '$core' created"
  fi
}

# ---------------------------------------------------------------------------
# Direct security.json write helpers
#
# All credential/role/permission writes go directly to security.json on disk.
# Solr's PathWatcher detects the file change and reloads auth config within
# a few seconds — no Security API write calls are needed or used.
#
# Using in-place write (cat > file) preserves the inode so inotify fires
# MODIFY (not DELETE+CREATE), which is what Solr's PathWatcher listens for.
# ---------------------------------------------------------------------------

_SEC_FILE="/var/solr/data/security.json"

# Low-level: apply a jq filter to security.json in-place (standalone only).
# In SolrCloud mode, security.json lives in ZooKeeper — use Security API instead.
_write_security() {
  if _is_cloud_mode; then
    _log "ERROR" "_write_security called in SolrCloud mode — use Security API"
    return 1
  fi
  local tmp
  tmp="$(mktemp)"
  chmod 600 "$tmp"
  if ! jq "$@" "$_SEC_FILE" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp" > "$_SEC_FILE"
  rm -f "$tmp"
  chmod 600 "$_SEC_FILE"
  chown 8983:8983 "$_SEC_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Cloud mode — Security API helpers
#
# In SolrCloud mode, security.json lives in ZooKeeper (managed by Solr).
# Direct file writes are ignored after first start; all changes must go
# through the Security API. Credentials are passed as plaintext — Solr
# hashes them server-side. jq builds payloads to handle special chars safely.
# ---------------------------------------------------------------------------

# POST to /solr/admin/authentication (credentials management)
_cloud_auth_api() {
  local payload="$1"
  _solr_api POST "/admin/authentication" "$payload" > /dev/null
}

# POST to /solr/admin/authorization (roles/permissions management)
_cloud_authz_api() {
  local payload="$1"
  _solr_api POST "/admin/authorization" "$payload" > /dev/null
}

# ---------------------------------------------------------------------------
# SolrCloud security bootstrap
#
# In SolrCloud mode, the embedded ZooKeeper initialises /security.json with
# an empty {} node before Solr reads the local security.json from disk.
# Solr therefore starts with authentication=disabled.  Detect this and upload
# the on-disk security.json to ZK so Solr reloads with proper auth.
# ---------------------------------------------------------------------------

_cloud_bootstrap_security() {
  local anon_code
  # Any anonymous request returns 401 when BasicAuthPlugin is active.
  anon_code="$(curl -s -o /dev/null -w '%{http_code}' \
    "${SOLR_BASE}/admin/authentication" 2>/dev/null)" || true

  if [ "$anon_code" = "401" ]; then
    _log "INFO" "SolrCloud: security already configured (anonymous → 401)"
    return 0
  fi

  _log "INFO" "SolrCloud: no auth configured (anonymous → ${anon_code}). Uploading security.json to ZK..."
  if [ ! -f "$_SEC_FILE" ]; then
    _log "ERROR" "security.json not found at $_SEC_FILE — cannot bootstrap security"
    return 1
  fi

  /opt/solr/bin/solr zk cp "file:${_SEC_FILE}" "zk:/security.json" -z "$ZK_HOST" 2>&1 \
    | while IFS= read -r line; do _log "INFO" "[zk] $line"; done

  # Wait for Solr's ZK watcher to detect the change and reload
  local i=0
  while [ "$i" -lt 20 ]; do
    anon_code="$(curl -s -o /dev/null -w '%{http_code}' \
      "${SOLR_BASE}/admin/authentication" 2>/dev/null)" || true
    if [ "$anon_code" = "401" ]; then
      _log "INFO" "SolrCloud: security reloaded after ${i}s"
      return 0
    fi
    sleep 1
    i=$((i+1))
  done

  _log "ERROR" "SolrCloud: security did not reload after ZK upload (still HTTP $anon_code)"
  return 1
}

# ---------------------------------------------------------------------------
# Cloud mode — Collections API helpers
# ---------------------------------------------------------------------------

_collection_exists() {
  local name="$1"
  local resp
  resp="$(_solr_api GET "/admin/collections?action=LIST&wt=json" 2>/dev/null)"
  printf '%s' "$resp" | jq -e --arg n "$name" '.collections | index($n) != null' > /dev/null 2>&1
}

# Upload configset to ZooKeeper via built-in solr CLI.
# Runs inside the Solr container where /opt/solr/bin/solr is available.
# ZK must be running (i.e., Solr already started) when this is called.
_ensure_configset_zk() {
  local conf_dir="/var/solr/data/configsets/moodle-tenant/conf"
  local resp
  resp="$(_solr_api GET "/admin/configs?action=LIST&wt=json" 2>/dev/null)"
  if printf '%s' "$resp" | jq -e '.configSets | index("moodle-tenant") != null' > /dev/null 2>&1; then
    _log "INFO" "Configset 'moodle-tenant' already in ZooKeeper"
    return 0
  fi
  _log "INFO" "Uploading configset 'moodle-tenant' to ZooKeeper ($ZK_HOST)"
  if [ ! -d "$conf_dir" ]; then
    _log "ERROR" "Configset source not found: $conf_dir"
    return 1
  fi
  /opt/solr/bin/solr zk upconfig \
    -n moodle-tenant \
    -d "$conf_dir" \
    -z "$ZK_HOST" 2>&1 | while IFS= read -r line; do _log "INFO" "[zk] $line"; done
  _log "INFO" "Configset 'moodle-tenant' uploaded"
}

_create_collection() {
  local name="$1"
  if _collection_exists "$name"; then
    _log "INFO" "Collection '$name' already exists"
    return 0
  fi
  _log "INFO" "Creating collection '$name'"
  if [ "$DRY_RUN" = "1" ]; then
    printf '[DRY-RUN] Would create collection: %s\n' "$name"
    return 0
  fi
  _ensure_configset_zk
  _solr_api GET "/admin/collections?action=CREATE&name=${name}&numShards=1&replicationFactor=1&collection.configName=moodle-tenant&wt=json" > /dev/null
  _log "INFO" "Collection '$name' created"
}

# ---------------------------------------------------------------------------
# Write credential — dispatches to Security API (cloud) or file (standalone)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Live security updates — Security API for both standalone and SolrCloud.
#
# Rationale for using Security API instead of direct file writes in standalone:
#   Direct file writes (cat > security.json) rely on Solr's PathWatcher via
#   inotify. This is unreliable in containerised CI environments (Docker
#   overlayfs blocks inotify MODIFY events). The Security API updates
#   Solr's in-memory auth state immediately, regardless of filesystem.
#
# Standalone vs SolrCloud differences:
#   Credentials/roles: identical payload in both modes.
#   Permissions: SolrCloud includes "collection" field (enforced by Solr).
#                Standalone omits it (not enforced; Caddy handles URL isolation).
#
# Restart persistence: powerinit.sh reads tenants.env and writes security.json
#   with collection fields on every container start — the on-disk file is
#   always rebuilt correctly, independent of live Security API state.
# ---------------------------------------------------------------------------

# _write_credential: Register or update a user's password via the Solr Security API.
# Sends a set-user payload to /solr/admin/authentication; Solr hashes the password server-side.
# In SolrCloud mode, also bootstraps security.json into ZooKeeper if not already active.
# Args: $1 - Solr username, $2 - plaintext password
# Returns: 0 on success, 1 on API failure
_write_credential() {
  local user="$1" pass="$2"
  _log "INFO" "Writing credential for '$user'"
  if [ "$DRY_RUN" = "1" ]; then printf '[DRY-RUN] Would write credential for: %s\n' "$user"; return 0; fi
  if _is_cloud_mode; then
    _cloud_bootstrap_security || return 1
  fi
  local payload
  payload="$(jq -n --arg u "$user" --arg p "$pass" '{"set-user": {($u): $p}}')"
  _cloud_auth_api "$payload"
}

# _block_user: Invalidate a tenant user's password by resetting it to a random value.
# The user record remains in security.json so the tenant can be re-enabled later.
# Args: $1 - Solr username
# Returns: 0 on success, 1 on API failure
_block_user() {
  local user="$1"
  _log "INFO" "Blocking user '$user'"
  if [ "$DRY_RUN" = "1" ]; then printf '[DRY-RUN] Would block user: %s\n' "$user"; return 0; fi
  local rand_pass payload
  rand_pass="$(_gen_password)"
  payload="$(jq -n --arg u "$user" --arg p "$rand_pass" '{"set-user": {($u): $p}}')"
  _cloud_auth_api "$payload"
}

# _write_user_role: Assign a Solr authorization role to a user via the Security API.
# Role must be a string (not array) — the Security API stores it as-is for role matching.
# Args: $1 - Solr username, $2 - role name (e.g. "tenant" or "tenant-schule_a")
# Returns: 0 on success, 1 on API failure
_write_user_role() {
  local user="$1" role="$2"
  _log "INFO" "Writing user-role: '$user' -> '$role'"
  if [ "$DRY_RUN" = "1" ]; then printf '[DRY-RUN] Would assign role: %s -> %s\n' "$user" "$role"; return 0; fi
  local payload
  # Role must be a string, not an array — Solr Security API stores it as-is.
  # Using [$r] (array) causes role-matching failures in authorization checks.
  payload="$(jq -n --arg u "$user" --arg r "$role" '{"set-user-role": {($u): $r}}')"
  _cloud_authz_api "$payload"
}

# Add permissions for a core/collection.
# SolrCloud: per-collection permissions (collection field enforced by Solr):
#   <name>-read  — role: [admin, support, tenant-x], paths: read-only Moodle endpoints
#   <name>-write — role: [admin, tenant-x],          paths: write endpoints (/update, /update/extract)
# Standalone: shared permissions without collection field — "tenant-read" and "tenant-write"
#   are idempotently upserted on every call (safe: Security API set-permission is a replace).
#   All tenants share role "tenant"; Caddy reverse proxy handles per-URL core isolation.
_add_permission() {
  local name="$1" role="$2" core="$3"
  if [ "$DRY_RUN" = "1" ]; then printf '[DRY-RUN] Would add permissions for core: %s\n' "$core"; return 0; fi

  if _is_cloud_mode; then
    _log "INFO" "Adding SolrCloud permissions '${name}-read' and '${name}-write' for collection '$core'"
    local read_payload write_payload
    read_payload="$(jq -n --arg n "${name}-read" --arg r "$role" --arg c "$core" \
      '{"set-permission": {
        "name": $n,
        "role": ["admin","support",$r],
        "collection": [$c],
        "path": ["/select","/admin/ping","/schema","/schema/*","/replication"]
      }}')"
    _cloud_authz_api "$read_payload"

    write_payload="$(jq -n --arg n "${name}-write" --arg r "$role" --arg c "$core" \
      '{"set-permission": {
        "name": $n,
        "role": ["admin",$r],
        "collection": [$c],
        "path": ["/update","/update/extract"]
      }}')"
    _cloud_authz_api "$write_payload"
  else
    _log "INFO" "Ensuring standalone shared tenant-read and tenant-write permissions"
    local read_payload write_payload
    read_payload='{"set-permission": {"name": "tenant-read", "role": ["admin","support","tenant"], "path": ["/select","/admin/ping","/schema","/schema/*","/replication"]}}'
    _cloud_authz_api "$read_payload"
    write_payload='{"set-permission": {"name": "tenant-write", "role": ["admin","tenant"], "path": ["/update","/update/extract"]}}'
    _cloud_authz_api "$write_payload"
  fi
}

# Remove both read and write permissions for a core.
# Expects the base name without -read/-write suffix.
# Standalone: shared tenant-read/tenant-write are NOT removed (other tenants still need them).
_remove_permission() {
  local perm_name="$1"
  if [ "$DRY_RUN" = "1" ]; then printf '[DRY-RUN] Would remove permissions: %s-read, %s-write\n' "$perm_name" "$perm_name"; return 0; fi
  if _is_cloud_mode; then
    _log "INFO" "Removing SolrCloud permissions '${perm_name}-read' and '${perm_name}-write'"
    local payload
    payload="$(jq -n --arg n "${perm_name}-read" '{"delete-permission": $n}')"
    _cloud_authz_api "$payload" || true
    payload="$(jq -n --arg n "${perm_name}-write" '{"delete-permission": $n}')"
    _cloud_authz_api "$payload" || true
  else
    _log "INFO" "Standalone: shared tenant-read/tenant-write are preserved when removing core '$perm_name'"
  fi
}

# _wait_for_security_reload: Poll Solr until the given user authenticates successfully.
# The Security API updates in-memory state immediately; this confirms propagation.
# Args: $1 - username, $2 - password, $3 - optional core for /admin/ping (default: system info),
#        $4 - max wait seconds (default: 10)
# Returns: 0 when auth succeeds within timeout; 0 with WARN log if timeout is exceeded
_wait_for_security_reload() {
  local user="$1" pass="$2" core="${3:-}" max_secs="${4:-10}"
  local url
  if [ -n "$core" ]; then
    url="${SOLR_BASE}/${core}/admin/ping"
  else
    url="${SOLR_BASE}/admin/info/system"
  fi
  local i=0
  while [ "$i" -lt "$max_secs" ]; do
    local code
    code="$(curl -so /dev/null -w '%{http_code}' -u "${user}:${pass}" \
      "$url" 2>/dev/null)"
    if [ "$code" = "200" ]; then
      _log "INFO" "Security reload confirmed after ${i}s"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  _log "WARN" "Security reload not confirmed after ${max_secs}s — continuing"
  return 0
}

# ---------------------------------------------------------------------------
# Endpoint verification after create/core-add
# ---------------------------------------------------------------------------
_test_endpoints() {
  local user="$1" pass="$2" core="$3"
  local base="${SOLR_BASE}/${core}"
  local ok=true

  _log "INFO" "[$core] Testing endpoints for user '$user'"

  local code
  code="$(curl -so /dev/null -w '%{http_code}' -u "${user}:${pass}" "${base}/admin/ping" 2>/dev/null)"
  if [ "$code" = "200" ]; then
    _log "OK" "[$core] /admin/ping (HTTP $code)"
  else
    _log "ERROR" "[$core] /admin/ping failed (HTTP $code)"
    ok=false
  fi

  code="$(curl -so /dev/null -w '%{http_code}' -u "${user}:${pass}" "${base}/select?q=*:*&rows=0" 2>/dev/null)"
  if [ "$code" = "200" ]; then
    _log "OK" "[$core] /select (HTTP $code)"
  else
    _log "ERROR" "[$core] /select failed (HTTP $code)"
    ok=false
  fi

  code="$(curl -so /dev/null -w '%{http_code}' -u "${user}:${pass}" \
    -X POST -H 'Content-Type: application/json' -d '{"commit":{}}' \
    "${base}/update" 2>/dev/null)"
  if [ "$code" = "200" ]; then
    _log "OK" "[$core] /update (HTTP $code)"
  else
    _log "ERROR" "[$core] /update failed (HTTP $code)"
    ok=false
  fi

  printf 'solr tika connectivity test\n' > /tmp/_solr_tika_test.txt
  code="$(curl -so /dev/null -w '%{http_code}' -u "${user}:${pass}" \
    -F "file=@/tmp/_solr_tika_test.txt" \
    "${base}/update/extract?extractOnly=true&wt=json" 2>/dev/null)"
  rm -f /tmp/_solr_tika_test.txt
  if [ "$code" = "200" ]; then
    _log "OK" "[$core] /update/extract Tika (HTTP $code)"
  else
    _log "ERROR" "[$core] /update/extract failed (HTTP $code) — Moodle file indexing requires this"
    ok=false
  fi

  code="$(curl -so /dev/null -w '%{http_code}' -u "${user}:${pass}" "${base}/schema" 2>/dev/null)"
  if [ "$code" = "200" ]; then
    _log "OK" "[$core] /schema (HTTP $code)"
  else
    _log "ERROR" "[$core] /schema failed (HTTP $code)"
    ok=false
  fi

  # Isolation check: in SolrCloud the collection field is enforced → 403 required.
  # In standalone mode, Caddy handles cross-core isolation externally; Solr itself
  # does not restrict cross-core URL access, so 403 is not expected here.
  local other_core
  other_core="$(grep '^TENANT_.*_CORES=' "$TENANTS_ENV" 2>/dev/null \
    | grep -v "=${core}" | head -1 | cut -d= -f2 | cut -d, -f1 | tr -d ' ')"
  if [ -n "$other_core" ] && [ "$other_core" != "$core" ]; then
    code="$(curl -so /dev/null -w '%{http_code}' -u "${user}:${pass}" \
      "${SOLR_BASE}/${other_core}/select?q=*:*&rows=0" 2>/dev/null)"
    if [ "$code" = "403" ]; then
      _log "OK" "[$core] Isolation: access to '$other_core' denied (HTTP 403)"
    elif _is_cloud_mode; then
      _log "ERROR" "[$core] ISOLATION FAILURE: access to '$other_core' returned HTTP $code (expected 403 in SolrCloud)"
      ok=false
    else
      _log "INFO" "[$core] Cross-core access to '$other_core' not restricted by Solr (HTTP $code) — use Caddy for URL isolation"
    fi
  fi

  if $ok; then
    _log "INFO" "[$core] All critical endpoints OK"
    return 0
  else
    _log "ERROR" "[$core] One or more critical endpoints failed — check above"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Print access box
# ---------------------------------------------------------------------------
_print_credentials() {
  local name="$1" user="$2" pass="$3" cores="$4"
  printf '\n'
  printf '  ╔═══════════════════════════════════════════════════╗\n'
  printf '  ║  Zugangsdaten fuer Moodle (%s):\n' "$name"
  printf '  ║  User:     %-38s║\n' "$user"
  printf '  ║  Password: %-38s║\n' "$pass"
  printf '  ║  Cores:    %-38s║\n' "$cores"
  printf '  ║  (Gespeichert in tenants.env)                     ║\n'
  printf '  ╚═══════════════════════════════════════════════════╝\n'
  printf '\n'
}

# ---------------------------------------------------------------------------
# Subcommand: create
# ---------------------------------------------------------------------------
cmd_create() {
  local name="" cores=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --cores) cores="$2"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      -*) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
      *) name="$1"; shift ;;
    esac
  done

  [ -z "$name" ] && { printf 'Usage: solr-tenant.sh create <name> --cores <core1>[,<core2>]\n' >&2; exit 1; }
  [ -z "$cores" ] && { printf 'Error: --cores is required\n' >&2; exit 1; }
  _validate_name "$name"

  _load_admin_creds
  _log_action "create $name --cores $cores"

  if _tenant_exists "$name" && [ "$DRY_RUN" = "0" ]; then
    printf 'Tenant "%s" already exists. Use core-add to add cores.\n' "$name" >&2
    exit 1
  fi

  local user="solr_${name}"
  local pass
  pass="$(_gen_password)"
  local role
  role="$(_get_tenant_role "$name")"

  # Create cores via Admin API
  IFS=',' read -ra CORE_ARRAY <<< "$cores"
  for core in "${CORE_ARRAY[@]}"; do
    core="$(echo "$core" | tr -d ' ')"
    [ -z "$core" ] && continue
    _create_core "$core"
  done

  # Write all security changes directly to security.json (no Security API writes).
  # Direct writes avoid API round-trip stripping the collection field.
  _write_credential "$user" "$pass"
  _write_user_role  "$user" "$role"
  for core in "${CORE_ARRAY[@]}"; do
    core="$(echo "$core" | tr -d ' ')"
    [ -z "$core" ] && continue
    _add_permission "tenant-${name}-${core}" "$role" "$core"
  done

  # Wait for Solr's PathWatcher to detect the file change and reload auth config
  _wait_for_security_reload "$user" "$pass" "${CORE_ARRAY[0]:-}"

  # Write tenants.env
  if [ "$DRY_RUN" = "0" ]; then
    _set_tenant_field "$name" "CORES" "$cores"
    _set_tenant_field "$name" "USER" "$user"
    _set_tenant_field "$name" "PASS" "$pass"
    _set_tenant_field "$name" "ACTIVE" "true"
  fi

  printf '✔ Tenant "%s" created\n' "$name"
  printf '  Cores: %s\n' "$cores"
  _print_credentials "$name" "$user" "$pass" "$cores"

  # Endpoint test (non-fatal on failure)
  for core in "${CORE_ARRAY[@]}"; do
    core="$(echo "$core" | tr -d ' ')"
    [ -z "$core" ] && continue
    _test_endpoints "$user" "$pass" "$core" || true
  done

  _log "INFO" "Tenant '$name' created successfully"
}

# ---------------------------------------------------------------------------
# Subcommand: delete
# ---------------------------------------------------------------------------
cmd_delete() {
  local name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      --force) shift ;;  # skip confirmation when called non-interactively
      -*) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
      *) name="$1"; shift ;;
    esac
  done

  [ -z "$name" ] && { printf 'Usage: solr-tenant.sh delete <name>\n' >&2; exit 1; }
  _validate_name "$name"

  if ! _tenant_exists "$name"; then
    printf 'Tenant "%s" not found in tenants.env\n' "$name" >&2
    exit 1
  fi

  _load_admin_creds
  _log_action "delete $name"

  local user
  user="$(_get_tenant_field "$name" "USER")"
  user="${user:-solr_${name}}"

  printf 'Deactivating tenant "%s" (user: %s) — data is preserved.\n' "$name" "$user"

  _block_user "$user"

  if [ "$DRY_RUN" = "0" ]; then
    _set_tenant_field "$name" "ACTIVE" "false"
  fi

  printf '✔ Tenant "%s" deactivated. Re-enable with: solr-tenant.sh enable %s\n' "$name" "$name"
  _log "INFO" "Tenant '$name' deactivated"
}

# ---------------------------------------------------------------------------
# Subcommand: enable
# ---------------------------------------------------------------------------
cmd_enable() {
  local name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      -*) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
      *) name="$1"; shift ;;
    esac
  done

  [ -z "$name" ] && { printf 'Usage: solr-tenant.sh enable <name>\n' >&2; exit 1; }
  _validate_name "$name"

  if ! _tenant_exists "$name"; then
    printf 'Tenant "%s" not found in tenants.env\n' "$name" >&2
    exit 1
  fi

  _load_admin_creds
  _log_action "enable $name"

  local user cores
  user="$(_get_tenant_field "$name" "USER")"
  user="${user:-solr_${name}}"
  cores="$(_get_tenant_field "$name" "CORES")"
  local role
  role="$(_get_tenant_role "$name")"

  local new_pass
  new_pass="$(_gen_password)"

  _write_credential "$user" "$new_pass"
  _write_user_role  "$user" "$role"

  IFS=',' read -ra CORE_ARRAY <<< "$cores"
  for core in "${CORE_ARRAY[@]}"; do
    core="$(echo "$core" | tr -d ' ')"
    [ -z "$core" ] && continue
    _add_permission "tenant-${name}-${core}" "$role" "$core"
  done

  _wait_for_security_reload "$user" "$new_pass" "${CORE_ARRAY[0]:-}"

  if [ "$DRY_RUN" = "0" ]; then
    _set_tenant_field "$name" "PASS" "$new_pass"
    _set_tenant_field "$name" "ACTIVE" "true"
  fi

  printf '✔ Tenant "%s" re-enabled\n' "$name"
  _print_credentials "$name" "$user" "$new_pass" "$cores"
  _log "INFO" "Tenant '$name' re-enabled"
}

# ---------------------------------------------------------------------------
# Subcommand: passwd
# ---------------------------------------------------------------------------
cmd_passwd() {
  local name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      -*) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
      *) name="$1"; shift ;;
    esac
  done

  [ -z "$name" ] && { printf 'Usage: solr-tenant.sh passwd <name>\n' >&2; exit 1; }
  _validate_name "$name"

  if ! _tenant_exists "$name"; then
    printf 'Tenant "%s" not found\n' "$name" >&2; exit 1
  fi

  _load_admin_creds
  _log_action "passwd $name"

  local user cores
  user="$(_get_tenant_field "$name" "USER")"
  user="${user:-solr_${name}}"
  cores="$(_get_tenant_field "$name" "CORES")"

  local new_pass first_core
  new_pass="$(_gen_password)"
  first_core="$(printf '%s' "$cores" | cut -d, -f1)"
  _write_credential "$user" "$new_pass"
  _wait_for_security_reload "$user" "$new_pass" "$first_core"

  if [ "$DRY_RUN" = "0" ]; then
    _set_tenant_field "$name" "PASS" "$new_pass"
  fi

  printf '✔ Password reset for tenant "%s"\n' "$name"
  _print_credentials "$name" "$user" "$new_pass" "$cores"
  _log "INFO" "Password reset for tenant '$name'"
}

# ---------------------------------------------------------------------------
# Subcommand: list
# ---------------------------------------------------------------------------
cmd_list() {
  if [ ! -f "$TENANTS_ENV" ]; then
    printf 'No tenants configured (tenants.env not found)\n'
    return 0
  fi

  printf '%-20s %-20s %-40s %-8s\n' "NAME" "USER" "CORES" "STATUS"
  printf '%s\n' "$(printf '%0.s-' {1..94})"

  # shellcheck disable=SC2094
  while IFS='=' read -r key value; do
    case "$key" in
      TENANT_*_CORES)
        local name="${key#TENANT_}"; name="${name%_CORES}"
        local user cores active
        user="$(grep "^TENANT_${name}_USER=" "$TENANTS_ENV" 2>/dev/null | cut -d= -f2-)"
        active="$(grep "^TENANT_${name}_ACTIVE=" "$TENANTS_ENV" 2>/dev/null | cut -d= -f2-)"
        cores="$value"
        local status="${active:-true}"
        printf '%-20s %-20s %-40s %-8s\n' "$name" "${user:-solr_${name}}" "$cores" "$status"
        ;;
    esac
  done < "$TENANTS_ENV"
}

# ---------------------------------------------------------------------------
# Subcommand: info
# ---------------------------------------------------------------------------
cmd_info() {
  local name="${1:-}"
  [ -z "$name" ] && { printf 'Usage: solr-tenant.sh info <name>\n' >&2; exit 1; }

  if ! _tenant_exists "$name"; then
    printf 'Tenant "%s" not found\n' "$name" >&2; exit 1
  fi

  local user cores active
  user="$(_get_tenant_field "$name" "USER")"
  cores="$(_get_tenant_field "$name" "CORES")"
  active="$(_get_tenant_field "$name" "ACTIVE")"

  printf '=== Tenant: %s ===\n' "$name"
  printf '  User:   %s\n' "${user:-solr_${name}}"
  printf '  Cores:  %s\n' "$cores"
  printf '  Status: %s\n' "${active:-true}"
  printf '  Role:   tenant-%s\n' "$name"
  printf '  (Password not shown — reset with: solr-tenant.sh passwd %s)\n' "$name"
}

# ---------------------------------------------------------------------------
# Subcommand: core-add
# ---------------------------------------------------------------------------
cmd_core_add() {
  local name="" core=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --core) core="$2"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      -*) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
      *) name="$1"; shift ;;
    esac
  done

  [ -z "$name" ] && { printf 'Usage: solr-tenant.sh core-add <name> --core <core>\n' >&2; exit 1; }
  [ -z "$core" ] && { printf 'Error: --core is required\n' >&2; exit 1; }
  _validate_name "$name"

  if ! _tenant_exists "$name"; then
    printf 'Tenant "%s" not found\n' "$name" >&2; exit 1
  fi

  _load_admin_creds
  _log_action "core-add $name --core $core"

  local user role existing_cores
  user="$(_get_tenant_field "$name" "USER")"
  user="${user:-solr_${name}}"
  role="$(_get_tenant_role "$name")"
  existing_cores="$(_get_tenant_field "$name" "CORES")"

  _create_core "$core"
  _add_permission "tenant-${name}-${core}" "$role" "$core"

  if [ "$DRY_RUN" = "0" ]; then
    local new_cores="${existing_cores},${core}"
    _set_tenant_field "$name" "CORES" "$new_cores"
  fi

  local pass
  pass="$(_get_tenant_field "$name" "PASS")"
  printf '✔ Core "%s" added to tenant "%s"\n' "$core" "$name"

  if [ -n "$pass" ]; then
    _wait_for_security_reload "$user" "$pass" "$core"
    _test_endpoints "$user" "$pass" "$core" || true
  fi

  _log "INFO" "Core '$core' added to tenant '$name'"
}

# ---------------------------------------------------------------------------
# Subcommand: core-remove
# ---------------------------------------------------------------------------
cmd_core_remove() {
  local name="" core=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --core) core="$2"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      -*) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
      *) name="$1"; shift ;;
    esac
  done

  [ -z "$name" ] && { printf 'Usage: solr-tenant.sh core-remove <name> --core <core>\n' >&2; exit 1; }
  [ -z "$core" ] && { printf 'Error: --core is required\n' >&2; exit 1; }

  if ! _tenant_exists "$name"; then
    printf 'Tenant "%s" not found\n' "$name" >&2; exit 1
  fi

  _load_admin_creds
  _log_action "core-remove $name --core $core"

  _remove_permission "tenant-${name}-${core}"

  if [ "$DRY_RUN" = "0" ]; then
    local existing_cores new_cores
    existing_cores="$(_get_tenant_field "$name" "CORES")"
    new_cores="$(echo "$existing_cores" | tr ',' '\n' | grep -v "^${core}$" | tr '\n' ',' | sed 's/,$//')"
    _set_tenant_field "$name" "CORES" "$new_cores"
  fi

  printf '✔ Permission for core "%s" removed from tenant "%s"\n' "$core" "$name"
  printf '  (Core data preserved — delete manually if needed)\n'
  _log "INFO" "Core '$core' removed from tenant '$name'"
}

# ---------------------------------------------------------------------------
# Subcommand: apply (idempotent re-apply from tenants.env)
# ---------------------------------------------------------------------------
cmd_apply() {
  _load_admin_creds
  _log_action "apply"

  if [ ! -f "$TENANTS_ENV" ]; then
    printf 'No tenants.env found — nothing to apply\n'
    return 0
  fi

  local count=0
  # shellcheck disable=SC2094
  while IFS='=' read -r key value; do
    case "$key" in
      TENANT_*_CORES)
        local name="${key#TENANT_}"; name="${name%_CORES}"
        local active user pass cores role
        active="$(grep "^TENANT_${name}_ACTIVE=" "$TENANTS_ENV" 2>/dev/null | cut -d= -f2-)"
        user="$(grep "^TENANT_${name}_USER=" "$TENANTS_ENV" 2>/dev/null | cut -d= -f2-)"
        pass="$(grep "^TENANT_${name}_PASS=" "$TENANTS_ENV" 2>/dev/null | cut -d= -f2-)"
        cores="$value"
        role="$(_get_tenant_role "$name")"
        user="${user:-solr_${name}}"

        if [ "${active:-true}" = "false" ]; then
          _block_user "$user"
          continue
        fi

        [ -z "$pass" ] && { _log "WARN" "No password for tenant $name — skipping"; continue; }

        _write_credential "$user" "$pass"
        _write_user_role  "$user" "$role"

        IFS=',' read -ra CORE_ARRAY <<< "$cores"
        for core in "${CORE_ARRAY[@]}"; do
          core="$(echo "$core" | tr -d ' ')"
          [ -z "$core" ] && continue
          _create_core "$core" || true
          _add_permission "tenant-${name}-${core}" "$role" "$core" || true
        done

        ((count++)) || true
        ;;
    esac
  done < "$TENANTS_ENV"

  # Wait for Solr to reload the updated security.json before returning
  if [ "$count" -gt 0 ]; then
    _log "INFO" "Waiting for Solr security reload..."
    sleep 5
  fi

  printf '✔ Applied %s tenant(s) from tenants.env\n' "$count"
  _log "INFO" "apply completed: $count tenant(s)"
}

# ---------------------------------------------------------------------------
# Subcommand: export (YAML for Ansible host_vars)
# ---------------------------------------------------------------------------
cmd_export() {
  if [ ! -f "$TENANTS_ENV" ]; then
    printf '# No tenants configured\nsolr_tenants: []\n'
    return 0
  fi

  printf '# Generated by solr-tenant.sh export\n'
  printf '# Add to host_vars and encrypt with ansible-vault\n'
  printf 'solr_tenants:\n'

  # shellcheck disable=SC2094
  while IFS='=' read -r key value; do
    case "$key" in
      TENANT_*_CORES)
        local name="${key#TENANT_}"; name="${name%_CORES}"
        local active cores
        active="$(grep "^TENANT_${name}_ACTIVE=" "$TENANTS_ENV" 2>/dev/null | cut -d= -f2-)"
        cores="$value"
        local state="present"
        [ "${active:-true}" = "false" ] && state="absent"

        local pass user
        pass="$(grep "^TENANT_${name}_PASS=" "$TENANTS_ENV" 2>/dev/null | cut -d= -f2-)"
        user="$(grep "^TENANT_${name}_USER=" "$TENANTS_ENV" 2>/dev/null | cut -d= -f2-)"

        printf '  - name: %s\n' "$name"
        printf '    state: %s\n' "$state"
        [ -n "$user" ] && printf '    solr_user: "%s"\n' "$user"
        [ -n "$pass" ] && printf '    solr_password: "%s"\n' "$pass"
        printf '    cores:\n'
        IFS=',' read -ra CORE_ARRAY <<< "$cores"
        for core in "${CORE_ARRAY[@]}"; do
          core="$(echo "$core" | tr -d ' ')"
          [ -n "$core" ] && printf '      - %s\n' "$core"
        done
        ;;
    esac
  done < "$TENANTS_ENV"
}

# ---------------------------------------------------------------------------
# Subcommand: caddy-config
# Generates a Caddyfile snippet for all active tenants.
# Each tenant gets a subdomain that only passes their own cores through to Solr.
# Apache: NOT generated here — an existing Moodle Apache config must not be touched.
# ---------------------------------------------------------------------------
cmd_caddy_config() {
  local domain="" port="${SOLR_PORT:-8983}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --domain) domain="$2"; shift 2 ;;
      --port)   port="$2"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      -*) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
      *) shift ;;
    esac
  done

  if [ -z "$domain" ]; then
    printf 'Usage: solr-tenant.sh caddy-config --domain solr.example.com [--port 8983]\n' >&2
    printf '\n' >&2
    printf 'Generates a Caddyfile with per-tenant subdomains for URL-level core isolation.\n' >&2
    printf 'Each tenant can only reach their own Solr cores through the proxy.\n' >&2
    exit 1
  fi

  printf '# ============================================================\n'
  printf '# Caddyfile — generated by solr-tenant.sh caddy-config\n'
  printf '# Domain:  %s\n' "$domain"
  printf '# Port:    %s\n' "$port"
  printf '# Mode:    %s\n' "${SOLR_MODE:-standalone}"
  printf '# WARNING: Do NOT edit manually — regenerate via solr-tenant.sh\n'
  printf '# ============================================================\n\n'

  printf '# Admin endpoint — restrict access in production (e.g., IP allowlist)\n'
  printf '%s {\n' "$domain"
  printf '    # tls /path/to/cert /path/to/key\n'
  printf '    reverse_proxy localhost:%s\n' "$port"
  printf '}\n\n'

  if [ ! -f "$TENANTS_ENV" ]; then
    printf '# No tenants configured (tenants.env not found)\n'
    return 0
  fi

  local tenant_count=0
  # shellcheck disable=SC2094
  while IFS='=' read -r key value; do
    case "$key" in
      TENANT_*_CORES)
        local name="${key#TENANT_}"; name="${name%_CORES}"
        local active cores
        active="$(grep "^TENANT_${name}_ACTIVE=" "$TENANTS_ENV" 2>/dev/null | cut -d= -f2-)"
        [ "${active:-true}" = "false" ] && continue

        cores="$value"
        # Build path matcher list: /solr/<core> and /solr/<core>/*
        local path_args=""
        IFS=',' read -ra CORE_ARRAY <<< "$cores"
        for core in "${CORE_ARRAY[@]}"; do
          core="$(printf '%s' "$core" | tr -d ' ')"
          [ -z "$core" ] && continue
          path_args="${path_args} /solr/${core} /solr/${core}/*"
        done

        # Subdomain: replace _ with - for valid hostname
        local tenant_host
        tenant_host="$(printf '%s' "$name" | tr '_' '-').${domain}"

        printf '# Tenant: %s — cores: %s\n' "$name" "$cores"
        printf '%s {\n' "$tenant_host"
        printf '    # tls /path/to/cert /path/to/key\n\n'
        printf '    @allowed path%s\n' "$path_args"
        printf '\n'
        printf '    handle @allowed {\n'
        printf '        reverse_proxy localhost:%s\n' "$port"
        printf '    }\n'
        printf '\n'
        printf '    handle {\n'
        printf '        respond "Forbidden" 403\n'
        printf '    }\n'
        printf '}\n\n'
        tenant_count=$((tenant_count + 1))
        ;;
    esac
  done < "$TENANTS_ENV"

  if [ "$tenant_count" -eq 0 ]; then
    printf '# No active tenants found in tenants.env\n'
  fi
  _log "INFO" "caddy-config generated: $tenant_count tenant(s) for domain $domain"
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: solr-tenant.sh <command> [options]

Commands:
  create <name> --cores <c1>[,<c2>]  Create tenant with one or more Solr cores
  delete <name>                       Deactivate tenant (data preserved)
  enable <name>                       Re-enable deactivated tenant (new password)
  passwd <name>                       Reset tenant password
  list                                List all tenants
  info <name>                         Show tenant details
  core-add <name> --core <core>       Add a core to existing tenant
  core-remove <name> --core <core>    Remove core permission from tenant
  apply                               Re-apply all tenants from tenants.env (idempotent)
  export                              YAML output for Ansible host_vars
  caddy-config --domain <d>           Generate Caddyfile for URL-level tenant isolation

Global options:
  --dry-run   Show what would happen without making changes

Modes (set SOLR_MODE in .env):
  standalone  (default) Direct file writes; isolation via Caddy reverse proxy
  solrcloud   Security API + Collections API; true collection-level isolation

Examples:
  solr-tenant.sh create schule_a --cores moodle_prod_a,moodle_test_a
  solr-tenant.sh list
  solr-tenant.sh core-add schule_a --core moodle_test_a
  solr-tenant.sh delete schule_b
  solr-tenant.sh apply
  solr-tenant.sh export
  solr-tenant.sh caddy-config --domain solr.example.com

Logs: /var/log/solr/tenant.log
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
COMMAND="${1:-}"
shift || true

case "$COMMAND" in
  create)       cmd_create "$@" ;;
  delete)       cmd_delete "$@" ;;
  enable)       cmd_enable "$@" ;;
  passwd)       cmd_passwd "$@" ;;
  list)         cmd_list "$@" ;;
  info)         cmd_info "$@" ;;
  core-add)     cmd_core_add "$@" ;;
  core-remove)  cmd_core_remove "$@" ;;
  apply)        cmd_apply "$@" ;;
  export)       cmd_export "$@" ;;
  caddy-config) cmd_caddy_config "$@" ;;
  --help|-h|help) usage ;;
  '')           usage; exit 1 ;;
  *)            printf 'Unknown command: %s\nRun: solr-tenant.sh --help\n' "$COMMAND" >&2; exit 1 ;;
esac
