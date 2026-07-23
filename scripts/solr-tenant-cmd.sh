#!/bin/bash
# Copyright (c) 2026 eLeDia.de / Bernd Schreistetter (bsc)
# Version: v3.4.12
#
# eLeDia Solr Tenant Commands — create, delete, enable, apply, export
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
ADMIN_USERS_ENV="${ADMIN_USERS_ENV:-/opt/solr/admin-users.env}"
LOG_FILE="${LOG_FILE:-/var/log/solr/tenant.log}"
SECURITY_JSON="${SECURITY_JSON:-/var/solr/data/security.json}"
BOOTSTRAP_STATE_FILE="${BOOTSTRAP_STATE_FILE:-/var/solr/data/.eledia-init/state.env}"
ENV_FILE="${ENV_FILE:-/var/solr/data/.env}"
DRY_RUN=0

# SolrCloud mode: set SOLR_MODE=solrcloud in .env
# Standalone (default): Security API + Core Admin API
# SolrCloud: Security API + Collections API + true collection isolation
SOLR_MODE="${SOLR_MODE:-}"

# Command Handlers Module — sourced by solr-tenant.sh

# --- cmd_create ---
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

  # Validate and create cores via Admin API.
  IFS=',' read -ra CORE_ARRAY <<< "$cores"
  for core in "${CORE_ARRAY[@]}"; do
    core="$(echo "$core" | tr -d ' ')"
    [ -z "$core" ] && continue
    _validate_core_name "$core"
  done
  for core in "${CORE_ARRAY[@]}"; do
    core="$(echo "$core" | tr -d ' ')"
    [ -z "$core" ] && continue
    if ! _create_core "$core"; then
      return 1
    fi
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

  # Write tenants.env before rebuilding collection-scoped SolrCloud permissions;
  # shared collections need a combined role list from the full tenant source of truth.
  if [ "$DRY_RUN" = "0" ]; then
    _set_tenant_field "$name" "CORES" "$cores"
    _set_tenant_field "$name" "USER" "$user"
    _set_tenant_field "$name" "PASS" "$pass"
    _set_tenant_field "$name" "ACTIVE" "true"
  fi

  if _is_cloud_mode; then
    _rebuild_tenant_permissions || return 1
    _ensure_all_permission_last || return 1
  else
    _ensure_all_permission_last || return 1
  fi

  if ! _is_cloud_mode; then
    if ! _wait_for_security_reload "$user" "$pass" "${CORE_ARRAY[0]:-}"; then
      return 1
    fi
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

# --- cmd_delete ---
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

# --- cmd_enable ---
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

  _validate_core_list "$cores"

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
  if [ "$DRY_RUN" = "0" ]; then
    _set_tenant_field "$name" "PASS" "$new_pass"
    _set_tenant_field "$name" "ACTIVE" "true"
  fi

  if _is_cloud_mode; then
    _rebuild_tenant_permissions || return 1
    _ensure_all_permission_last || return 1
  else
    _ensure_all_permission_last || return 1
  fi

  if ! _is_cloud_mode; then
    if ! _wait_for_security_reload "$user" "$new_pass" "${CORE_ARRAY[0]:-}"; then
      return 1
    fi
  fi

  printf '✔ Tenant "%s" re-enabled\n' "$name"
  _print_credentials "$name" "$user" "$new_pass" "$cores"
  _log "INFO" "Tenant '$name' re-enabled"
}

# ---------------------------------------------------------------------------
# Subcommand: passwd
# ---------------------------------------------------------------------------

# --- cmd_passwd ---
cmd_passwd() {
  local name="" provided_pass="" pass_from_stdin=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --password) provided_pass="$2"; shift 2 ;;
      --password-stdin) pass_from_stdin=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -*) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
      *) name="$1"; shift ;;
    esac
  done

  [ -z "$name" ] && { printf 'Usage: solr-tenant.sh passwd <name> [--password <password> | --password-stdin]\n' >&2; exit 1; }

  # --password-stdin: read the password from stdin so orchestration layers
  # (Ansible) never expose it in the host process list (/proc/<pid>/cmdline).
  if [ "$pass_from_stdin" = "1" ]; then
    if [ -n "$provided_pass" ]; then
      printf 'ERROR: --password and --password-stdin are mutually exclusive\n' >&2
      exit 1
    fi
    IFS= read -r provided_pass || true
    if [ -z "$provided_pass" ]; then
      printf 'ERROR: --password-stdin given but stdin was empty\n' >&2
      exit 1
    fi
  fi
  _validate_name "$name"

  if ! _tenant_exists "$name"; then
    printf 'Tenant "%s" not found\n' "$name" >&2; exit 1
  fi

  _load_admin_creds
  _log_action "passwd $name"

  local user cores role
  user="$(_get_tenant_field "$name" "USER")"
  user="${user:-solr_${name}}"
  cores="$(_get_tenant_field "$name" "CORES")"
  role="$(_get_tenant_role "$name")"

  _validate_core_list "$cores"

  local new_pass first_core
  if [ -n "$provided_pass" ]; then
    new_pass="$provided_pass"
  else
    new_pass="$(_gen_password)"
  fi
  first_core="$(printf '%s' "$cores" | cut -d, -f1)"
  _write_credential "$user" "$new_pass"

  if [ "$DRY_RUN" = "0" ]; then
    _set_tenant_field "$name" "PASS" "$new_pass"
  fi

  if _is_cloud_mode; then
    _write_user_role "$user" "$role" || return 1
    _rebuild_tenant_permissions || return 1
    _ensure_all_permission_last || return 1
  else
    if ! _wait_for_security_reload "$user" "$new_pass" "$first_core"; then
      return 1
    fi
  fi

  printf '✔ Password reset for tenant "%s"\n' "$name"
  _print_credentials "$name" "$user" "$new_pass" "$cores"
  _log "INFO" "Password reset for tenant '$name'"
}

# ---------------------------------------------------------------------------
# Subcommand: list
# ---------------------------------------------------------------------------

# --- cmd_list ---
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

# --- cmd_info ---
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

# --- cmd_core_add ---
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

  _validate_core_name "$core"

  # Skip if core already assigned to this tenant (idempotent)
  if echo ",${existing_cores}," | grep -q ",${core},"; then
    _log "INFO" "Core '$core' already assigned to tenant '$name' — skipping"
    printf '✔ Core "%s" already assigned to tenant "%s"\\n' "$core" "$name"
    return 0
  fi

  if ! _create_core "$core"; then
    return 1
  fi
  _add_permission "tenant-${name}-${core}" "$role" "$core"

  if [ "$DRY_RUN" = "0" ]; then
    local new_cores="${existing_cores},${core}"
    _set_tenant_field "$name" "CORES" "$new_cores"
  fi

  if _is_cloud_mode; then
    _rebuild_tenant_permissions || return 1
    _ensure_all_permission_last || return 1
  else
    _ensure_all_permission_last || return 1
  fi

  local pass
  pass="$(_get_tenant_field "$name" "PASS")"
  printf '✔ Core "%s" added to tenant "%s"\n' "$core" "$name"

  if [ -n "$pass" ]; then
    if ! _is_cloud_mode; then
      if ! _wait_for_security_reload "$user" "$pass" "$core"; then
        return 1
      fi
    fi
    _test_endpoints "$user" "$pass" "$core" || true
  fi

  _log "INFO" "Core '$core' added to tenant '$name'"
}

# ---------------------------------------------------------------------------
# Subcommand: core-remove
# ---------------------------------------------------------------------------

# --- cmd_core_remove ---
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

  _validate_core_name "$core"

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

# --- cmd_apply ---
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

        _validate_core_list "$cores"

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
          if ! _create_core "$core"; then
            return 1
          fi
        done

        ((count++)) || true
        ;;
    esac
  done < "$TENANTS_ENV"

  if [ "$count" -gt 0 ] && _is_cloud_mode; then
    _rebuild_tenant_permissions || return 1
    _ensure_all_permission_last || return 1
  fi

  # Wait for Solr to reload the updated security.json before returning
  if [ "$count" -gt 0 ]; then
    _log "INFO" "Waiting for Solr security reload..."
    sleep 5
  fi

  printf '✔ Applied %s tenant(s) from tenants.env\n' "$count"
  _log "INFO" "apply completed: $count tenant(s)"
}

# ---------------------------------------------------------------------------
# Subcommand: sync-sot (.env + tenants.env + admin-users.env are source of truth)
#
# Strategy:
#  1) Apply desired state from tenants.env to API (cmd_apply)
#  2) Read users from Solr API
#  3) Apply extra admin/support users from admin-users.env
#  4) Build allow-list from .env fixed users + admin-users.env + tenants.env users
#  4) For API users not in allow-list: rotate to random password via API
#     (blocks unknown/out-of-band credentials without deleting user entries)
# ---------------------------------------------------------------------------

# --- cmd_sync_sot ---
cmd_sync_sot() {
  _load_admin_creds
  _log_action "sync-sot"

  cmd_apply

  if [ ! -f "$TENANTS_ENV" ] || ! grep -q '^TENANT_.*_CORES=' "$TENANTS_ENV"; then
    _log "INFO" "No tenant collections configured — skipping sync-sot"
    return 0
  fi

  if _is_cloud_mode; then
    _rebuild_tenant_permissions || return 1
    _ensure_all_permission_last || return 1
  fi

  if [ -f "$ADMIN_USERS_ENV" ]; then
    local admin_key admin_value admin_name admin_field admin_role admin_pass
    declare -A extra_admin_role_map extra_admin_pass_map

    while IFS='=' read -r admin_key admin_value; do
      case "$admin_key" in
        '#'*|'') continue ;;
      esac
      if echo "$admin_key" | grep -qE '^ADMIN_[A-Za-z0-9_]+_(ROLE|PASS)$'; then
        admin_name="${admin_key#ADMIN_}"
        admin_field="${admin_name##*_}"
        admin_name="${admin_name%_*}"
        case "$admin_field" in
          ROLE) extra_admin_role_map["$admin_name"]="$admin_value" ;;
          PASS) extra_admin_pass_map["$admin_name"]="$admin_value" ;;
        esac
      fi
    done < "$ADMIN_USERS_ENV"

    for admin_name in "${!extra_admin_pass_map[@]}"; do
      admin_role="${extra_admin_role_map[$admin_name]:-admin}"
      admin_pass="${extra_admin_pass_map[$admin_name]:-}"
      [ -n "$admin_pass" ] || continue
      case "$admin_role" in
        admin|support) ;;
        *) printf 'ERROR: invalid role in %s for user %s: %s\n' "$ADMIN_USERS_ENV" "$admin_name" "$admin_role" >&2; return 1 ;;
      esac
      _write_credential "$admin_name" "$admin_pass" || return 1
      _write_user_role "$admin_name" "$admin_role" || return 1
    done
  fi

  local auth_json api_users
  auth_json="$(_solr_api GET "/admin/authentication" 2>/dev/null || true)"
  if [ -z "$auth_json" ]; then
    printf 'ERROR: Could not read /admin/authentication from Solr API\n' >&2
    return 1
  fi

  api_users="$(printf '%s' "$auth_json" | jq -r '.authentication.credentials | keys[]?' 2>/dev/null || true)"

  local allow_file
  allow_file="$(mktemp)"
  chmod 600 "$allow_file"

  {
    printf '%s\n' "${SOLR_ADMIN_USER:-admin}"
    printf '%s\n' "${SOLR_SUPPORT_USER:-support}"
    [ -n "${SOLR_MOODLE_USER:-}" ] && printf '%s\n' "${SOLR_MOODLE_USER}"

    if [ -f "$ADMIN_USERS_ENV" ]; then
      awk -F= '/^ADMIN_[A-Za-z0-9_]+_PASS=/ { key=$1; sub(/^ADMIN_/, "", key); sub(/_PASS$/, "", key); print key }' "$ADMIN_USERS_ENV"
    fi

    if [ -f "$TENANTS_ENV" ]; then
      local -A tenant_user_map tenant_active_map tenant_has_cores
      local k v name

      while IFS='=' read -r k v; do
        case "$k" in
          TENANT_*_USER)
            name="${k#TENANT_}"; name="${name%_USER}"
            tenant_user_map["$name"]="$v"
            ;;
          TENANT_*_ACTIVE)
            name="${k#TENANT_}"; name="${name%_ACTIVE}"
            tenant_active_map["$name"]="$v"
            ;;
          TENANT_*_CORES)
            name="${k#TENANT_}"; name="${name%_CORES}"
            tenant_has_cores["$name"]=1
            ;;
        esac
      done < "$TENANTS_ENV"

      for name in "${!tenant_has_cores[@]}"; do
        local user
        user="${tenant_user_map[$name]:-solr_${name}}"
        [ -n "$user" ] && printf '%s\n' "$user"
      done
    fi
  } | sed '/^$/d' | sort -u > "$allow_file"

  local rotated=0 kept=0
  while IFS= read -r u; do
    [ -z "$u" ] && continue
    if grep -qx "$u" "$allow_file"; then
      kept=$((kept + 1))
      continue
    fi

    _log "WARN" "Unknown API user '$u' (not present in .env/tenants.env) -> rotating password"
    if [ "$DRY_RUN" = "1" ]; then
      printf '[DRY-RUN] Would rotate unknown API user: %s\n' "$u"
      continue
    fi

    local rand_pass payload
    rand_pass="$(_gen_password)"
    payload="$(jq -n --arg user "$u" --arg pass "$rand_pass" '{"set-user": {($user): $pass}}')"
    _cloud_auth_api "$payload"
    rotated=$((rotated + 1))
  done <<< "$api_users"

  rm -f "$allow_file"
  printf '✔ SOT sync done: kept=%s rotated_unknown=%s\n' "$kept" "$rotated"
  _log "INFO" "sync-sot completed: kept=$kept rotated_unknown=$rotated"
}

# ---------------------------------------------------------------------------
# Subcommand: rebuild-permissions
#
# Rebuilds tenant authorization rules from tenants.env and keeps the broad
# fallback permission `all` as the last rule. This is intentionally exposed as
# a first-class command so orchestration layers (Ansible) delegate tenant ACL
# mutation to the container script instead of carrying their own curl/jq writer.
# ---------------------------------------------------------------------------

# --- cmd_rebuild_permissions ---
cmd_rebuild_permissions() {
  _load_admin_creds
  _log_action "rebuild-permissions"

  if ! _is_cloud_mode; then
    printf '✔ Standalone mode: tenant permissions are shared; nothing to rebuild\n'
    return 0
  fi

  if [ ! -f "$TENANTS_ENV" ]; then
    printf 'ERROR: tenants.env not found: %s\n' "$TENANTS_ENV" >&2
    return 1
  fi

  _rebuild_tenant_permissions || return 1
  _ensure_all_permission_last || return 1

  printf '✔ Rebuilt tenant permissions from tenants.env and kept fallback all last\n'
  _log "INFO" "rebuild-permissions completed"
}

# ---------------------------------------------------------------------------
# Subcommand: export (YAML for Ansible host_vars)
# ---------------------------------------------------------------------------

# --- cmd_export ---
cmd_export() {
  if [ ! -f "$TENANTS_ENV" ]; then
    printf '# No tenants configured\nsolr_tenants: []\n'
    return 0
  fi

  printf '# Generated by solr-tenant.sh export\n'
  printf '# Add to host_vars and encrypt with ansible-vault\n'
  printf '# Runtime Source of Truth: Solr Security API + Collections in ZooKeeper\n'
  printf '# This host_vars block mirrors runtime state managed via sync-sot/apply\n'
  printf 'solr_runtime_source_of_truth:\n'
  printf '  authority: "runtime-api-zookeeper"\n'
  printf '  sync_command: "solr-tenant.sh sync-sot"\n'
  printf '  tenants_env: "%s"\n' "$TENANTS_ENV"
  printf '  mode: "%s"\n' "${SOLR_MODE:-standalone}"
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
# Subcommand: runtime-truth (live Solr API / ZooKeeper state)
# ---------------------------------------------------------------------------

# --- cmd_runtime_truth ---
cmd_runtime_truth() {
  _load_admin_creds
  _log_action "runtime-truth"

  local auth_json authz_json collections_json mode
  mode="${SOLR_MODE:-standalone}"

  auth_json="$(_solr_api GET "/admin/authentication" 2>/dev/null || true)"
  authz_json="$(_solr_api GET "/admin/authorization" 2>/dev/null || true)"

  if [ -z "$auth_json" ] || [ -z "$authz_json" ]; then
    printf 'ERROR: could not read Solr Security API runtime state\n' >&2
    return 1
  fi

  if _is_cloud_mode; then
    collections_json="$(_solr_api GET "/admin/collections?action=LIST&wt=json" 2>/dev/null || true)"
  else
    collections_json='{"collections":[]}'
  fi

  printf '# Runtime truth from live Solr APIs\n'
  printf '# authentication=/admin/authentication authorization=/admin/authorization\n'
  if _is_cloud_mode; then
    printf '# collections=/admin/collections?action=LIST&wt=json ZooKeeper=%s\n' "$ZK_HOST"
  else
    printf '# standalone note: tenant-to-core URL isolation lives in tenants.env/proxy, not Solr collections\n'
  fi
  printf 'solr_runtime_source_of_truth:\n'
  printf '  authority: "live-solr-api"\n'
  printf '  mode: "%s"\n' "$mode"
  printf '  zookeeper: "%s"\n' "$([ "$mode" = "solrcloud" ] && printf '%s' "$ZK_HOST" || printf 'not-used')"
  printf '  tenants:\n'

  local users user roles_json tenant_role tenant_name collections active_marker
  users="$(printf '%s' "$auth_json" | jq -r '.authentication.credentials | keys[]?' 2>/dev/null | sort -u)"

  while IFS= read -r user; do
    [ -z "$user" ] && continue

    roles_json="$(printf '%s' "$authz_json" | jq -c --arg u "$user" '.authorization["user-role"][$u] // [] | if type == "array" then . else [.] end' 2>/dev/null || printf '[]')"
    tenant_role="$(printf '%s' "$roles_json" | jq -r '.[]? | select(startswith("tenant-"))' 2>/dev/null | head -1)"

    case "$user" in
      "${SOLR_ADMIN_USER:-admin}"|"${SOLR_SUPPORT_USER:-support}"|"${SOLR_MOODLE_USER:-moodle}")
        continue
        ;;
    esac

    if [ -n "$tenant_role" ]; then
      tenant_name="${tenant_role#tenant-}"
    elif printf '%s' "$user" | grep -q '^solr_'; then
      tenant_name="${user#solr_}"
      tenant_role="tenant"
    else
      tenant_name="unmanaged_${user}"
    fi

    active_marker="runtime-present"
    if [ -f "$TENANTS_ENV" ] && grep -q "^TENANT_${tenant_name}_ACTIVE=false" "$TENANTS_ENV" 2>/dev/null; then
      active_marker="runtime-present-desired-inactive"
    fi

    collections=""
    if _is_cloud_mode && [ -n "$tenant_role" ] && [ "$tenant_role" != "tenant" ]; then
      collections="$(printf '%s' "$authz_json" | jq -r --arg role "$tenant_role" '
        .authorization.permissions[]?
        | select((.role // []) | tostring | contains($role))
        | (.collection // [])[]?
      ' 2>/dev/null | sort -u | paste -sd, -)"
    fi

    printf '    - name: "%s"\n' "$tenant_name"
    printf '      user: "%s"\n' "$user"
    printf '      role: "%s"\n' "${tenant_role:-unmanaged-runtime-user}"
    printf '      state: "%s"\n' "$active_marker"
    if [ -n "$collections" ]; then
      printf '      collections:\n'
      printf '%s\n' "$collections" | tr ',' '\n' | while IFS= read -r c; do
        [ -n "$c" ] && printf '        - "%s"\n' "$c"
      done
    else
      printf '      collections: []\n'
    fi
  done <<< "$users"

  if _is_cloud_mode; then
    printf '  runtime_collections:\n'
    printf '%s' "$collections_json" | jq -r '.collections[]?' 2>/dev/null | sed '/^\.system$/d' | sort -u | while IFS= read -r c; do
      [ -n "$c" ] && printf '    - "%s"\n' "$c"
    done
  fi
}

# ---------------------------------------------------------------------------
# Subcommand: healthcheck
# Validates Solr availability and only checks runtime drift once the instance
# has finished its first bootstrap (security.json exists + auth endpoint online).
# Fresh volumes are reported as bootstrap-needed instead of drift.
# ---------------------------------------------------------------------------

# --- cmd_healthcheck ---
cmd_healthcheck() {
  _load_admin_creds
  _log_action "healthcheck"

  local system_code auth_code drift_out drift_rc bootstrap_state bootstrap_reason
  bootstrap_reason=""
  bootstrap_state="$(if [ -s "$BOOTSTRAP_STATE_FILE" ]; then printf 'present'; else printf 'missing'; fi)"

  system_code="$(curl -s -o /dev/null -w '%{http_code}' -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "${SOLR_BASE}/admin/info/system" 2>/dev/null || true)"
  auth_code="$(curl -s -o /dev/null -w '%{http_code}' \
    "${SOLR_BASE}/admin/authentication" 2>/dev/null || true)"

  if [ "$system_code" != "200" ]; then
    printf 'ERROR: Solr system endpoint unhealthy (HTTP %s)\n' "$system_code" >&2
    return 1
  fi

  if [ ! -s "$SECURITY_JSON" ]; then
    bootstrap_reason="security.json missing or empty"
  elif [ "$auth_code" != "401" ]; then
    bootstrap_reason="authentication endpoint not yet active (HTTP ${auth_code})"
  fi

  if [ -n "$bootstrap_reason" ]; then
    # if the bootstrap marker says bootstrap already ran but auth
    # is still not active, security is stuck — report unhealthy instead of
    # staying "healthy" forever with an unauthenticated Solr.
    if [ "$bootstrap_state" = "present" ]; then
      printf 'ERROR: Security bootstrap incomplete after bootstrap ran (system=%s auth=%s marker=%s): %s\n' \
        "$system_code" "$auth_code" "$bootstrap_state" "$bootstrap_reason" >&2
      _log "ERROR" "healthcheck: bootstrap-stuck (${bootstrap_reason}, marker=${bootstrap_state})"
      return 1
    fi
    printf '✔ Bootstrap needed (system=%s auth=%s marker=%s): %s\n' \
      "$system_code" "$auth_code" "$bootstrap_state" "$bootstrap_reason"
    _log "INFO" "healthcheck: bootstrap-needed (${bootstrap_reason}, marker=${bootstrap_state})"
    return 0
  fi

  local health_cores core schema_resp handler_resp cluster_resp
  health_cores="$(awk -F= '/^TENANT_.*_CORES=/{print $2}' "$TENANTS_ENV" 2>/dev/null | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d' | sort -u)"
  if [ -z "$health_cores" ] && [ -n "${SOLR_CORE_NAME:-}" ]; then
    health_cores="$SOLR_CORE_NAME"
  fi

  for core in $health_cores; do
    schema_resp="$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" \
      "${SOLR_BASE}/${core}/schema/fields/solr_filecontent?wt=json" 2>/dev/null || true)"
    if ! printf '%s' "$schema_resp" | grep -q '"name":"solr_filecontent"'; then
      printf 'ERROR: Moodle file schema missing for %s: field solr_filecontent not available\n' "$core" >&2
      return 1
    fi

    handler_resp="$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" \
      "${SOLR_BASE}/${core}/config/requestHandler?componentName=/update/extract&wt=json" 2>/dev/null || true)"
    if ! printf '%s' "$handler_resp" | grep -q 'solr.extraction.ExtractingRequestHandler'; then
      printf 'ERROR: Moodle file indexing handler missing for %s: /update/extract not configured\n' "$core" >&2
      return 1
    fi

    if _is_cloud_mode; then
      cluster_resp="$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" \
        "${SOLR_BASE}/admin/collections?action=CLUSTERSTATUS&collection=${core}&wt=json" 2>/dev/null || true)"
      if ! printf '%s' "$cluster_resp" | grep -q '"configName":"eLeDia-moodle-tenant"'; then
        printf 'ERROR: SolrCloud collection %s does not use configset eLeDia-moodle-tenant\n' "$core" >&2
        return 1
      fi
    fi
  done

  printf '✔ Healthcheck passed (system=%s auth=%s mode=%s schema=ok)\n' "$system_code" "$auth_code" "${SOLR_MODE:-standalone}"
  return 0
}

# ---------------------------------------------------------------------------
# Subcommand: config-repair
# Self-heals Moodle Solr configsets from the image/repo source, uploads them to
# ZooKeeper in SolrCloud, reloads tenant cores/collections, then runs healthcheck.
# ---------------------------------------------------------------------------

cmd_config_repair() {
  _load_admin_creds
  _log_action "config-repair"

  local src_dir dst_dir default_dst_dir legacy_dst_dir health_cores core reload_resp
  if [ -d "/opt/solr/eledia-config" ] && [ -f "/opt/solr/eledia-config/managed-schema" ] && [ -f "/opt/solr/eledia-config/solrconfig.xml" ]; then
    src_dir="/opt/solr/eledia-config"
  elif [ -d "/opt/solr/eledia-config-image" ] && [ -f "/opt/solr/eledia-config-image/managed-schema" ] && [ -f "/opt/solr/eledia-config-image/solrconfig.xml" ]; then
    src_dir="/opt/solr/eledia-config-image"
  else
    printf 'ERROR: no valid eLeDia config source found (/opt/solr/eledia-config or /opt/solr/eledia-config-image)\n' >&2
    return 1
  fi

  dst_dir="/var/solr/data/configsets/eLeDia-moodle-tenant/conf"
  default_dst_dir="/var/solr/data/configsets/_default/conf"
  legacy_dst_dir="/var/solr/data/configsets/moodle-tenant/conf"

  for target in "$dst_dir" "$default_dst_dir"; do
    mkdir -p "$target"
    cp -f "$src_dir/managed-schema" "$target/managed-schema"
    cp -f "$src_dir/solrconfig.xml" "$target/solrconfig.xml"
    if [ -d "$src_dir/lang" ]; then
      mkdir -p "$target/lang"
      cp -f "$src_dir/lang"/* "$target/lang/" 2>/dev/null || true
    fi
  done
  if [ -d "$legacy_dst_dir" ]; then
    cp -f "$src_dir/managed-schema" "$legacy_dst_dir/managed-schema"
    cp -f "$src_dir/solrconfig.xml" "$legacy_dst_dir/solrconfig.xml"
  fi
  chown -R 8983:8983 /var/solr/data/configsets 2>/dev/null || true
  printf '✔ Local configsets refreshed from %s\n' "$src_dir"

  health_cores="$(awk -F= '/^TENANT_.*_CORES=/{print $2}' "$TENANTS_ENV" 2>/dev/null | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d' | sort -u)"
  if [ -z "$health_cores" ] && [ -n "${SOLR_CORE_NAME:-}" ]; then
    health_cores="$SOLR_CORE_NAME"
  fi

  if _is_cloud_mode; then
    /opt/solr/bin/solr zk upconfig -n eLeDia-moodle-tenant -d "$dst_dir" -z "$ZK_HOST" 2>&1 | while IFS= read -r line; do _log "INFO" "[zk] $line"; done
    printf '✔ ZooKeeper configset eLeDia-moodle-tenant uploaded\n'
    for core in $health_cores; do
      reload_resp="$(_solr_api GET "/admin/collections?action=RELOAD&name=${core}&wt=json" 2>/dev/null || true)"
      if printf '%s' "$reload_resp" | grep -q '"status":0'; then
        printf '✔ Collection reloaded: %s\n' "$core"
      else
        printf 'WARN: collection reload may have failed for %s\n' "$core" >&2
      fi
    done
  else
    for core in $health_cores; do
      reload_resp="$(_solr_api GET "/admin/cores?action=RELOAD&core=${core}&wt=json" 2>/dev/null || true)"
      if printf '%s' "$reload_resp" | grep -q '"status":0'; then
        printf '✔ Core reloaded: %s\n' "$core"
      else
        printf 'WARN: core reload may have failed for %s\n' "$core" >&2
      fi
    done
  fi

  cmd_healthcheck
}

# ---------------------------------------------------------------------------
# Subcommand: drift-detect
# Detect runtime drift between tenants.env (desired state) and Solr runtime state
# (authentication + authorization + collections API in SolrCloud).
# ---------------------------------------------------------------------------

# --- cmd_drift_detect ---
cmd_drift_detect() {
  _load_admin_creds
  _log_action "drift-detect"

  local desired_file actual_users_file desired_users_file actual_collections_file desired_collections_file
  desired_file="$(mktemp)"
  actual_users_file="$(mktemp)"
  desired_users_file="$(mktemp)"
  actual_collections_file="$(mktemp)"
  desired_collections_file="$(mktemp)"

  if [ ! -f "$TENANTS_ENV" ]; then
    printf 'ERROR: tenants.env not found: %s\n' "$TENANTS_ENV" >&2
    rm -f "$desired_file" "$actual_users_file" "$desired_users_file" "$actual_collections_file" "$desired_collections_file"
    return 1
  fi

  printf '# Runtime drift report\n'
  printf 'mode=%s\n' "${SOLR_MODE:-standalone}"
  printf 'tenants_env=%s\n\n' "$TENANTS_ENV"

  local tenants_content
  tenants_content="$(cat "$TENANTS_ENV")"

  # Build desired state snapshot from all tenants in tenants.env. Inactive tenants
  # keep their Solr user/collections as managed preserved state; cmd_apply blocks
  # inactive users by rotating their passwords instead of deleting runtime records.
  while IFS='=' read -r key value; do
    case "$key" in
      TENANT_*_CORES)
        local name user cores
        name="${key#TENANT_}"; name="${name%_CORES}"

        user="$(printf '%s\n' "$tenants_content" | grep "^TENANT_${name}_USER=" 2>/dev/null | cut -d= -f2-)"
        user="${user:-solr_${name}}"
        cores="$value"

        printf '%s|%s|%s\n' "$name" "$user" "$cores" >> "$desired_file"
      ;;
    esac
  done <<< "$tenants_content"

  cut -d'|' -f2 "$desired_file" | sort -u > "$desired_users_file"
  cut -d'|' -f3 "$desired_file" | tr ',' '\n' | sed '/^$/d' | tr -d ' ' | sort -u > "$desired_collections_file"

  # Runtime users from Solr Security API
  local auth_json
  auth_json="$(_solr_api GET "/admin/authentication" 2>/dev/null || true)"
  if [ -z "$auth_json" ]; then
    printf 'ERROR: could not read /admin/authentication\n' >&2
    rm -f "$desired_file" "$actual_users_file" "$desired_users_file" "$actual_collections_file" "$desired_collections_file"
    return 1
  fi
  printf '%s' "$auth_json" | jq -r '.authentication.credentials | keys[]?' | sort -u > "$actual_users_file"

  # Runtime collections only in SolrCloud
  if _is_cloud_mode; then
    local coll_json
    coll_json="$(_solr_api GET "/admin/collections?action=LIST&wt=json" 2>/dev/null || true)"
    printf '%s' "$coll_json" | jq -r '.collections[]?' | sed '/^\.system$/d' | sort -u > "$actual_collections_file"
  else
    : > "$actual_collections_file"
  fi

  local drift=0

  printf '[USERS] desired(active tenants) minus runtime:\n'
  if comm -23 "$desired_users_file" "$actual_users_file" | sed '/^$/d' | sed 's/^/  MISSING_RUNTIME_USER: /'; then :; fi
  if [ -n "$(comm -23 "$desired_users_file" "$actual_users_file")" ]; then drift=1; fi

  printf '[USERS] runtime minus desired(active tenants):\n'
  if comm -13 "$desired_users_file" "$actual_users_file" | grep -vE '^(admin|support|moodle)$' | sed '/^$/d' | sed 's/^/  UNMANAGED_RUNTIME_USER: /'; then :; fi
  if comm -13 "$desired_users_file" "$actual_users_file" | grep -qvE '^(admin|support|moodle)$'; then drift=1; fi

  if _is_cloud_mode; then
    printf '[COLLECTIONS] desired(active tenants) minus runtime:\n'
    if comm -23 "$desired_collections_file" "$actual_collections_file" | sed '/^$/d' | sed 's/^/  MISSING_RUNTIME_COLLECTION: /'; then :; fi
    if [ -n "$(comm -23 "$desired_collections_file" "$actual_collections_file")" ]; then drift=1; fi

    printf '[COLLECTIONS] runtime minus desired(active tenants):\n'
    if comm -13 "$desired_collections_file" "$actual_collections_file" | sed '/^$/d' | sed 's/^/  UNMANAGED_RUNTIME_COLLECTION: /'; then :; fi
    if [ -n "$(comm -13 "$desired_collections_file" "$actual_collections_file")" ]; then drift=1; fi
  fi

  if [ "$drift" -eq 0 ]; then
    printf '\n✔ No runtime drift detected\n'
    _log "INFO" "drift-detect: no drift"
  else
    printf '\n✖ Runtime drift detected\n'
    _log "WARN" "drift-detect: drift detected"
  fi

  rm -f "$desired_file" "$actual_users_file" "$desired_users_file" "$actual_collections_file" "$desired_collections_file"
  return "$drift"
}

# --- cmd_drift_remediate ---
cmd_drift_remediate() {
  _load_admin_creds
  _log_action "drift-remediate"

  if [ ! -f "$TENANTS_ENV" ]; then
    printf 'ERROR: tenants.env not found: %s\n' "$TENANTS_ENV" >&2
    return 1
  fi

  printf '# Drift remediation\n'
  printf 'strategy=sync-sot\n'
  printf 'tenants_env=%s\n\n' "$TENANTS_ENV"

  if cmd_sync_sot; then
    printf '\n✔ Drift remediation applied via sync-sot\n'
    return 0
  fi

  printf '\n✖ Drift remediation failed\n' >&2
  return 1
}

# ---------------------------------------------------------------------------
# Subcommand: caddy-config
# Generates a Caddyfile snippet for all active tenants.
# Each tenant gets a subdomain that only passes their own cores through to Solr.
# Apache: NOT generated here — an existing Moodle Apache config must not be touched.
# ---------------------------------------------------------------------------

# --- cmd_caddy_config ---
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
        _validate_core_list "$cores"
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

# --- usage ---
usage() {
  cat <<'EOF'
Usage: solr-tenant.sh <command> [options]

Commands:
  create <name> --cores <c1>[,<c2>]  Create tenant with one or more Solr cores
  delete <name>                       Deactivate tenant (data preserved)
  enable <name>                       Re-enable deactivated tenant (new password)
  passwd <name> [--password <pass>]     Reset tenant password or enforce provided one
  list                                List all tenants
  info <name>                         Show tenant details
  core-add <name> --core <core>       Add a core to existing tenant
  core-remove <name> --core <core>    Remove core permission from tenant
  apply                               Re-apply all tenants from tenants.env (idempotent)
  sync-sot                            Enforce .env+tenants.env as SOT and rotate unknown API users
  rebuild-permissions                 Rebuild tenant ACLs from tenants.env and keep all last
  config-repair                       Self-heal Moodle configsets, upload/reload, then healthcheck
  healthcheck                         Validate Solr availability, bootstrap state, schema/configsets, and tenant drift
  drift-detect                        Detect runtime drift vs tenants.env (users/collections)
  drift-remediate                     Reconcile runtime drift via sync-sot
  export                              YAML output for Ansible host_vars
  runtime-truth                       YAML from live Solr API/ZooKeeper runtime state
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
  solr-tenant.sh runtime-truth
  solr-tenant.sh caddy-config --domain solr.example.com

Logs: /var/log/solr/tenant.log
EOF
}
