#!/bin/bash
# Copyright (c) 2026 eLeDia GmbH / Bernd Schreistetter (bsc)
# SPDX-License-Identifier: MIT
# Version: v3.1.0
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
LOG_FILE="${LOG_FILE:-/var/log/solr/tenant.log}"
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

# --- cmd_passwd ---
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

  # Skip if core already assigned to this tenant (idempotent)
  if echo ",${existing_cores}," | grep -q ",${core},"; then
    _log "INFO" "Core '$core' already assigned to tenant '$name' — skipping"
    printf '✔ Core "%s" already assigned to tenant "%s"\\n' "$core" "$name"
    return 0
  fi

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
# Subcommand: sync-sot (.env + tenants.env are source of truth)
#
# Strategy:
#  1) Apply desired state from tenants.env to API (cmd_apply)
#  2) Read users from Solr API
#  3) Build allow-list from .env fixed users + tenants.env users
#  4) For API users not in allow-list: rotate to random password via API
#     (blocks unknown/out-of-band credentials without deleting user entries)
# ---------------------------------------------------------------------------

# --- cmd_sync_sot ---
cmd_sync_sot() {
  _load_admin_creds
  _log_action "sync-sot"

  cmd_apply

  if _is_cloud_mode; then
    _rebuild_tenant_permissions || return 1
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
        local user active
        user="${tenant_user_map[$name]:-solr_${name}}"
        active="${tenant_active_map[$name]:-true}"
        [ "$active" = "false" ] && continue
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
  passwd <name>                       Reset tenant password
  list                                List all tenants
  info <name>                         Show tenant details
  core-add <name> --core <core>       Add a core to existing tenant
  core-remove <name> --core <core>    Remove core permission from tenant
  apply                               Re-apply all tenants from tenants.env (idempotent)
  sync-sot                            Enforce .env+tenants.env as SOT and rotate unknown API users
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




