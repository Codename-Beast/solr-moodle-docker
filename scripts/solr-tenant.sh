#!/bin/bash
# =========================================
# Solr Multi-Tenant CLI
# Developer: BSC Bernd Schreistetter
# Company: Eledia.de
# Version: v3.0.0
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
SOLR_BASE="http://localhost:${SOLR_PORT:-8983}/solr"
TENANTS_ENV="${TENANTS_ENV:-/opt/solr/tenants.env}"
LOG_FILE="${LOG_FILE:-/var/log/solr/tenant.log}"
ENV_FILE="${ENV_FILE:-/var/solr/data/.env}"
DRY_RUN=0

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

_solr_api() {
  local method="${1:-GET}"
  local path="$2"
  local data="${3:-}"
  local http_code response

  if [ -n "$data" ]; then
    response="$(curl -sf -o /tmp/_solr_resp -w '%{http_code}' \
      -u "${ADMIN_USER}:${ADMIN_PASS}" \
      -X "$method" \
      -H 'Content-Type: application/json' \
      -d "$data" \
      "${SOLR_BASE}${path}" 2>&1)"
  else
    response="$(curl -sf -o /tmp/_solr_resp -w '%{http_code}' \
      -u "${ADMIN_USER}:${ADMIN_PASS}" \
      -X "$method" \
      "${SOLR_BASE}${path}" 2>&1)"
  fi

  http_code="$response"
  if [ "$http_code" != "200" ]; then
    _log "ERROR" "Solr API $method $path returned HTTP $http_code"
    cat /tmp/_solr_resp 2>/dev/null || true
    return 1
  fi
  cat /tmp/_solr_resp 2>/dev/null || true
}

_gen_password() {
  openssl rand -base64 36 | tr -d '/+=' | head -c 32
}

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

_core_exists() {
  local core="$1"
  # Solr's STATUS API returns {"status":{"core":{}}} even for non-existent cores.
  # Only an existing core has "instanceDir" in its status object.
  _solr_api GET "/admin/cores?action=STATUS&core=${core}&wt=json" 2>/dev/null \
    | grep -q '"instanceDir"'
}

_tenant_exists() {
  local name="$1"
  grep -q "^TENANT_${name}_CORES=" "$TENANTS_ENV" 2>/dev/null
}

# Read tenants.env value: TENANT_<name>_<field>
_get_tenant_field() {
  local name="$1" field="$2"
  grep "^TENANT_${name}_${field}=" "$TENANTS_ENV" 2>/dev/null | cut -d= -f2-
}

# Write or update a single TENANT_<name>_<field>=<value> line
_set_tenant_field() {
  local name="$1" field="$2" value="$3"
  local key="TENANT_${name}_${field}"
  touch "$TENANTS_ENV"
  if grep -q "^${key}=" "$TENANTS_ENV"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$TENANTS_ENV"
  else
    printf '%s=%s\n' "$key" "$value" >> "$TENANTS_ENV"
  fi
}

# Remove all TENANT_<name>_* lines
_remove_tenant_lines() {
  local name="$1"
  sed -i "/^TENANT_${name}_/d" "$TENANTS_ENV"
}

# Solr password hash (double SHA256, same as powerinit.sh)
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

# Create a Solr core via Admin API
_create_core() {
  local core="$1"
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

# Low-level: apply a jq filter to security.json in-place.
_write_security() {
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

# Write a hashed credential for user directly to security.json.
_write_credential() {
  local user="$1" pass="$2"
  _log "INFO" "Writing credential for '$user'"
  if [ "$DRY_RUN" = "1" ]; then
    printf '[DRY-RUN] Would write credential for: %s\n' "$user"
    return 0
  fi
  local hash
  hash="$(_hash_password "$pass")"
  # shellcheck disable=SC2016
  _write_security --arg u "$user" --arg h "$hash" \
    '.authentication.credentials[$u] = $h'
}

# Write a random (blocking) credential — user cannot log in.
_block_user() {
  local user="$1"
  _log "INFO" "Blocking user '$user'"
  if [ "$DRY_RUN" = "1" ]; then
    printf '[DRY-RUN] Would block user: %s\n' "$user"
    return 0
  fi
  local rand_pass hash
  rand_pass="$(_gen_password)"
  hash="$(_hash_password "$rand_pass")"
  # shellcheck disable=SC2016
  _write_security --arg u "$user" --arg h "$hash" \
    '.authentication.credentials[$u] = $h'
}

# Write user-role mapping directly to security.json.
_write_user_role() {
  local user="$1" role="$2"
  _log "INFO" "Writing user-role: '$user' -> '$role'"
  if [ "$DRY_RUN" = "1" ]; then
    printf '[DRY-RUN] Would assign role: %s -> %s\n' "$user" "$role"
    return 0
  fi
  # shellcheck disable=SC2016
  _write_security --arg u "$user" --arg r "$role" \
    '.authorization["user-role"][$u] = $r'
}

# Add a collection-scoped permission directly to security.json.
# collection MUST be a JSON array [$c] — a bare string is parsed as null by
# Solr's Java Permission class (List<String> cast fails on String), which
# disables collection filtering and breaks tenant isolation.
_add_permission() {
  local name="$1" role="$2" core="$3"
  _log "INFO" "Adding permission '$name' for core '$core'"
  if [ "$DRY_RUN" = "1" ]; then
    printf '[DRY-RUN] Would add permission: %s -> %s\n' "$name" "$core"
    return 0
  fi
  # Remove any stale entry with the same name first
  # shellcheck disable=SC2016
  _write_security --arg n "$name" \
    'del(.authorization.permissions[] | select(.name == $n))' || return 1
  # Append new permission; collection as array so Solr parses it as List<String>
  # shellcheck disable=SC2016
  _write_security --arg n "$name" --arg r "$role" --arg c "$core" \
    '.authorization.permissions += [{
      "name": $n,
      "role": ["admin","support",$r],
      "collection": [$c],
      "path": ["/select","/update","/update/extract","/admin/ping","/schema","/schema/*","/replication"]
    }]'
}

# Remove a permission directly from security.json.
_remove_permission() {
  local perm_name="$1"
  _log "INFO" "Removing permission '$perm_name'"
  if [ "$DRY_RUN" = "1" ]; then
    printf '[DRY-RUN] Would remove permission: %s\n' "$perm_name"
    return 0
  fi
  # shellcheck disable=SC2016
  _write_security --arg n "$perm_name" \
    'del(.authorization.permissions[] | select(.name == $n))'
}

# Poll until Solr has reloaded security.json and the given user can authenticate.
# Tests /solr/<core>/admin/ping which the predefined "health" permission allows
# for any authenticated user. Solr's PathWatcher reloads within 1-5 seconds.
# Args: user pass [core] [max_secs]
_wait_for_security_reload() {
  local user="$1" pass="$2" core="${3:-}" max_secs="${4:-20}"
  local url
  if [ -n "$core" ]; then
    url="${SOLR_BASE}/${core}/admin/ping"
  else
    # Fall back to system info (requires admin; used when no core is known)
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
    _log "WARN" "[$core] /update/extract HTTP $code (Tika may need configuration)"
  fi

  code="$(curl -so /dev/null -w '%{http_code}' -u "${user}:${pass}" "${base}/schema" 2>/dev/null)"
  if [ "$code" = "200" ]; then
    _log "OK" "[$core] /schema (HTTP $code)"
  else
    _log "ERROR" "[$core] /schema failed (HTTP $code)"
    ok=false
  fi

  # Isolation: access to another tenant's core must be denied
  local other_core
  other_core="$(grep '^TENANT_.*_CORES=' "$TENANTS_ENV" 2>/dev/null \
    | grep -v "=${core}" | head -1 | cut -d= -f2 | cut -d, -f1 | tr -d ' ')"
  if [ -n "$other_core" ] && [ "$other_core" != "$core" ]; then
    code="$(curl -so /dev/null -w '%{http_code}' -u "${user}:${pass}" \
      "${SOLR_BASE}/${other_core}/select?q=*:*&rows=0" 2>/dev/null)"
    if [ "$code" = "403" ]; then
      _log "OK" "[$core] Isolation: access to '$other_core' denied (HTTP 403)"
    else
      _log "ERROR" "[$core] ISOLATION FAILURE: access to '$other_core' returned HTTP $code (expected 403)"
      ok=false
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
  local role="tenant-${name}"

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
  local role="tenant-${name}"

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
  role="tenant-${name}"
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
        role="tenant-${name}"
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

        printf '  - name: %s\n' "$name"
        printf '    state: %s\n' "$state"
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

Global options:
  --dry-run   Show what would happen without making changes

Examples:
  solr-tenant.sh create schule_a --cores moodle_prod_a,moodle_test_a
  solr-tenant.sh list
  solr-tenant.sh core-add schule_a --core moodle_test_a
  solr-tenant.sh delete schule_b
  solr-tenant.sh apply
  solr-tenant.sh export

Logs: /var/log/solr/tenant.log
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
COMMAND="${1:-}"
shift || true

case "$COMMAND" in
  create)     cmd_create "$@" ;;
  delete)     cmd_delete "$@" ;;
  enable)     cmd_enable "$@" ;;
  passwd)     cmd_passwd "$@" ;;
  list)       cmd_list "$@" ;;
  info)       cmd_info "$@" ;;
  core-add)   cmd_core_add "$@" ;;
  core-remove) cmd_core_remove "$@" ;;
  apply)      cmd_apply "$@" ;;
  export)     cmd_export "$@" ;;
  --help|-h|help) usage ;;
  '')         usage; exit 1 ;;
  *)          printf 'Unknown command: %s\nRun: solr-tenant.sh --help\n' "$COMMAND" >&2; exit 1 ;;
esac
