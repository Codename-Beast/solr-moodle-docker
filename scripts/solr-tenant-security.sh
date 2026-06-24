#!/bin/bash
# Copyright (c) 2026 eLeDia.de / Bernd Schreistetter (bsc)
# Version: v3.4.10
#
# eLeDia Solr Tenant Security — credentials, roles, permissions
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

# Security Operations Module — sourced by solr-tenant.sh

# --- _write_credential ---
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

# --- _block_user ---
_block_user() {
  local user="$1"
  _log "INFO" "Blocking user '$user'"
  if [ "$DRY_RUN" = "1" ]; then printf '[DRY-RUN] Would block user: %s\n' "$user"; return 0; fi
  local rand_pass payload
  rand_pass="$(_gen_password)"
  payload="$(jq -n --arg u "$user" --arg p "$rand_pass" '{"set-user": {($u): $p}}')"
  _cloud_auth_api "$payload"
}

# _write_user_role: Assign Solr authorization roles to a user via the Security API.
# SolrCloud tenants get both a shared `tenant` role for Moodle's core-level
# /admin/system readiness check and their tenant-specific role for collection
# isolation. Standalone uses the shared `tenant` role only.
# Args: $1 - Solr username, $2 - role name (e.g. "tenant" or "tenant-schule_a")
# Returns: 0 on success, 1 on API failure

# --- _write_user_role ---
_write_user_role() {
  local user="$1" role="$2"
  _log "INFO" "Writing user-role: '$user' -> '$role'"
  if [ "$DRY_RUN" = "1" ]; then printf '[DRY-RUN] Would assign role: %s -> %s\n' "$user" "$role"; return 0; fi
  local payload
  if [ "$role" = "tenant" ]; then
    payload="$(jq -n --arg u "$user" --arg r "$role" '{"set-user-role": {($u): $r}}')"
  else
    payload="$(jq -n --arg u "$user" --arg r "$role" '{"set-user-role": {($u): ["tenant", $r]}}')"
  fi
  _cloud_authz_api "$payload"
}

# Add permissions for a core/collection.
# SolrCloud: per-collection permissions (collection field enforced by Solr):
#   <name>-read  — role: [admin, support, tenant-x], paths: read-only Moodle endpoints
#   <name>-write — role: [admin, tenant-x],          paths: write endpoints (/update, /update/extract)
# Standalone: shared permissions without collection field — "tenant-read" and "tenant-write"
#   are idempotently upserted on every call (safe: Security API set-permission is a replace).
#   All tenants share role "tenant"; Caddy reverse proxy handles per-URL core isolation.

# --- _add_permission ---
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
        "path": ["/select","/admin/ping","/admin/system","/admin/system/","/schema","/schema/*","/replication"]
      }}')"
    _cloud_authz_api "$read_payload" || return 1

    write_payload="$(jq -n --arg n "${name}-write" --arg r "$role" --arg c "$core" \
      '{"set-permission": {
        "name": $n,
        "role": ["admin",$r],
        "collection": [$c],
        "path": ["/update","/update/extract"]
      }}')"
    _cloud_authz_api "$write_payload" || return 1
  else
    _log "INFO" "Ensuring standalone shared tenant-read and tenant-write permissions"
    local read_payload write_payload
    read_payload='{"set-permission": {"name": "tenant-read", "role": ["admin","support","tenant"], "path": ["/select","/admin/ping","/admin/system","/admin/system/","/schema","/schema/*","/replication"]}}'
    _cloud_authz_api "$read_payload"
    write_payload='{"set-permission": {"name": "tenant-write", "role": ["admin","tenant"], "path": ["/update","/update/extract"]}}'
    _cloud_authz_api "$write_payload"
  fi
}

# Delete authorization permissions by their numeric index.
# Solr's Security API does not accept permission names for delete-permission;
# posting {"delete-permission":"all"} returns responseHeader.status=0 but only
# embeds an errorMessages entry. Delete descending so later indexes stay stable.
_delete_permission_indexes() {
  local indexes="$1" idx
  [ -z "$indexes" ] && return 0

  while IFS= read -r idx; do
    [ -z "$idx" ] && continue
    _cloud_authz_api "$(jq -n --argjson i "$idx" '{"delete-permission": $i}')" || true
  done <<< "$(printf '%s\n' "$indexes" | sort -rn)"
}

# Rebuild collection-scoped tenant permissions and keep them ahead of generic rules.
# Solr stops at the first matching permission. Therefore one collection shared by
# multiple tenants must have one combined role list, not one permission per tenant.
_rebuild_tenant_permissions() {
  _is_cloud_mode || return 0

  local authz tenant_indexes
  authz="$(_solr_api GET "/admin/authorization" 2>/dev/null || true)"
  tenant_indexes="$(printf '%s' "$authz" | jq -r '.authorization.permissions[]? | select((.name // "") | test("^(tenant|collection)-.*-(read|write)$")) | .index' 2>/dev/null || true)"
  _delete_permission_indexes "$tenant_indexes"

  local tenant_names t_name t_user t_role t_cores t_active c
  local read_payload write_payload read_roles_json write_roles_json roles
  declare -A collection_roles
  tenant_names="$(grep '^TENANT_.*_CORES=' "$TENANTS_ENV" 2>/dev/null | sed -E 's/^TENANT_(.+)_CORES=.*/\1/' | sort -u)"

  while IFS= read -r t_name; do
    [ -z "$t_name" ] && continue
    t_active="$(_get_tenant_field "$t_name" "ACTIVE")"
    [ "$t_active" = "false" ] && continue

    t_user="$(_get_tenant_field "$t_name" "USER")"
    [ -z "$t_user" ] && t_user="solr_${t_name}"
    t_role="$(_get_tenant_role "$t_name")"
    _write_user_role "$t_user" "$t_role" || return 1

    t_cores="$(_get_tenant_field "$t_name" "CORES")"
    IFS=',' read -ra CORE_ARRAY <<< "$t_cores"
    for c in "${CORE_ARRAY[@]}"; do
      c="$(echo "$c" | tr -d ' ')"
      [ -z "$c" ] && continue
      collection_roles["$c"]="${collection_roles[$c]:-} $t_role"
    done
  done <<< "$tenant_names"

  for c in "${!collection_roles[@]}"; do
    roles="$(printf '%s' "${collection_roles[$c]}" | tr ' ' '\n' | sed '/^$/d' | sort -u)"
    read_roles_json="$(printf 'admin\nsupport\n%s\n' "$roles" | sed '/^$/d' | sort -u | jq -R . | jq -s .)"
    write_roles_json="$(printf 'admin\n%s\n' "$roles" | sed '/^$/d' | sort -u | jq -R . | jq -s .)"

    # Generic Solr permissions such as "read" and "update" are broad first-match
    # rules. Tenant collection permissions must be inserted before them or the
    # tenant-specific role will never be evaluated and writes return HTTP 403.
    local read_before update_before
    authz="$(_solr_api GET "/admin/authorization" 2>/dev/null || true)"
    read_before="$(printf '%s' "$authz" | jq -r '.authorization.permissions[]? | select(.name=="read") | .index' 2>/dev/null | head -1)"
    [ -n "$read_before" ] || read_before="null"
    read_payload="$(jq -n --arg n "collection-${c}-read" --arg col "$c" --argjson roles "$read_roles_json" --argjson before "$read_before" \
      '{"set-permission": ({
        "name": $n,
        "role": $roles,
        "collection": [$col],
        "path": ["/select","/admin/ping","/admin/system","/admin/system/","/schema","/schema/*","/replication"]
      } + (if $before == null then {} else {"before": $before} end))}')"
    _cloud_authz_api "$read_payload" || return 1

    authz="$(_solr_api GET "/admin/authorization" 2>/dev/null || true)"
    update_before="$(printf '%s' "$authz" | jq -r '.authorization.permissions[]? | select(.name=="update") | .index' 2>/dev/null | head -1)"
    [ -n "$update_before" ] || update_before="null"
    write_payload="$(jq -n --arg n "collection-${c}-write" --arg col "$c" --argjson roles "$write_roles_json" --argjson before "$update_before" \
      '{"set-permission": ({
        "name": $n,
        "role": $roles,
        "collection": [$col],
        "path": ["/update","/update/extract"]
      } + (if $before == null then {} else {"before": $before} end))}')"
    _cloud_authz_api "$write_payload" || return 1
  done

  return 0
}

# Keep fallback 'all' permission at the very end to avoid broad-match shadowing.
# Solr evaluates permissions in order; if 'all' is not last, tenant/core rules can be ignored.
# This function re-adds 'all' after dynamic updates in SolrCloud mode.

# --- _ensure_all_permission_last ---
_ensure_all_permission_last() {
  _is_cloud_mode || return 0
  [ "$DRY_RUN" = "1" ] && return 0

  local authz all_indexes
  authz="$(_solr_api GET "/admin/authorization" 2>/dev/null || true)"
  [ -z "$authz" ] && return 0

  all_indexes="$(printf '%s' "$authz" | jq -r '.authorization.permissions[]? | select(.name=="all") | .index' 2>/dev/null || true)"

  # Remove all existing 'all' entries first.
  _delete_permission_indexes "$all_indexes"

  # Re-add fallback rule so it lands at the bottom.
  _cloud_authz_api '{"set-permission":{"name":"all","role":"admin"}}' || return 1
  return 0
}

# Remove both read and write permissions for a core.
# Expects the base name without -read/-write suffix.
# Standalone: shared tenant-read/tenant-write are NOT removed (other tenants still need them).

# --- _remove_permission ---
_remove_permission() {
  local perm_name="$1"
  if [ "$DRY_RUN" = "1" ]; then printf '[DRY-RUN] Would remove permissions: %s-read, %s-write\n' "$perm_name" "$perm_name"; return 0; fi
  if _is_cloud_mode; then
    _log "INFO" "Removing SolrCloud permissions '${perm_name}-read' and '${perm_name}-write'"
    local authz remove_indexes
    authz="$(_solr_api GET "/admin/authorization" 2>/dev/null || true)"
    remove_indexes="$(printf '%s' "$authz" | jq -r --arg r "${perm_name}-read" --arg w "${perm_name}-write" \
      '.authorization.permissions[]? | select(.name==$r or .name==$w) | .index' 2>/dev/null || true)"
    _delete_permission_indexes "$remove_indexes"
  else
    _log "INFO" "Standalone: shared tenant-read/tenant-write are preserved when removing core '$perm_name'"
  fi
}

# _wait_for_security_reload: Poll Solr until the given user authenticates successfully.
# The Security API updates in-memory state immediately; this confirms propagation.
# Args: $1 - username, $2 - password, $3 - optional core for /admin/ping (default: system info),
#        $4 - max wait seconds (default: 10)
# Returns: 0 when auth succeeds within timeout; 1 with ERROR log if timeout is exceeded

# --- _wait_for_security_reload ---
_wait_for_security_reload() {
  local user="$1" pass="$2" core="${3:-}" max_secs="${4:-30}"
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
  _log "ERROR" "Security reload not confirmed after ${max_secs}s"
  return 1
}

# ---------------------------------------------------------------------------
# Endpoint verification after create/core-add
# ---------------------------------------------------------------------------

# --- _test_endpoints ---
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

# --- _print_credentials ---
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
