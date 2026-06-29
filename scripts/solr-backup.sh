#!/bin/bash
# Copyright (c) 2026 eLeDia.de / Bernd Schreistetter (bsc)
# Version: v3.4.10

# =========================================
# Solr Backup — Multi-Tenant
# =========================================
# Backs up all Solr cores defined in tenants.env via Solr Replication API.
# Run inside the solr container:
#   docker exec <container> /opt/solr/scripts/solr-backup.sh

set -euo pipefail

SOLR_BASE="${SOLR_BASE:-http://localhost:8983/solr}"
TENANTS_ENV="${TENANTS_ENV:-/opt/solr/tenants.env}"
BACKUP_DIR="${BACKUP_DIR:-/var/solr/data/backup}"
LOG_FILE="${LOG_FILE:-/var/log/solr/tenant.log}"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"

# _log: Write a timestamped [BACKUP] message to stdout and $LOG_FILE.
# Args: $@ - message text
# Returns: nothing
_log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] [BACKUP] %s\n' "$ts" "$*" | tee -a "$LOG_FILE"
}

# _read_env_key: Read one simple KEY=value assignment from an env file.
# Avoids sourcing .env so unrelated variables or shell code cannot affect backup.
_read_env_key() {
  local env_file="$1" key="$2" value
  [ -f "$env_file" ] || return 1
  value="$(grep -E "^${key}=" "$env_file" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '\r')"
  [ -n "$value" ] || return 1
  case "$value" in
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
  esac
  printf '%s' "$value"
}

# _load_admin_creds: Load only admin credentials from /var/solr/data/.env or /.env.
# Sets ADMIN_USER and ADMIN_PASS from SOLR_ADMIN_USER / SOLR_ADMIN_PASSWORD.
# Args: none
# Returns: nothing; exits with code 1 if SOLR_ADMIN_PASSWORD is not set
_load_admin_creds() {
  local env_file="/var/solr/data/.env" loaded_user="" loaded_pass=""
  if [ -f "$env_file" ]; then
    loaded_user="$(_read_env_key "$env_file" "SOLR_ADMIN_USER" || true)"
    loaded_pass="$(_read_env_key "$env_file" "SOLR_ADMIN_PASSWORD" || true)"
  fi
  if [ -z "$loaded_pass" ] && [ -f "/.env" ]; then
    loaded_user="${loaded_user:-$(_read_env_key "/.env" "SOLR_ADMIN_USER" || true)}"
    loaded_pass="$(_read_env_key "/.env" "SOLR_ADMIN_PASSWORD" || true)"
  fi
  ADMIN_USER="${SOLR_ADMIN_USER:-${loaded_user:-admin}}"
  ADMIN_PASS="${SOLR_ADMIN_PASSWORD:-${loaded_pass:-}}"
  if [ -z "$ADMIN_PASS" ]; then
    _log "ERROR: SOLR_ADMIN_PASSWORD not set"
    exit 1
  fi
}

# backup_core: Trigger a Solr Replication API backup for a single core.
# The backup is written to $BACKUP_DIR/<core>_<timestamp>/ inside the container.
# Args: $1 - core name
# Returns: 0 on success (HTTP 200 from Replication API), 1 on failure
backup_core() {
  local core="$1"
  local backup_name="${core}_${TIMESTAMP}"
  local backup_path="${BACKUP_DIR}/${backup_name}"

  _log "Backing up core '$core' -> $backup_path"

  local http_code
  http_code="$(curl -so /dev/null -w '%{http_code}' \
    -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "${SOLR_BASE}/${core}/replication?command=backup&location=${BACKUP_DIR}&name=${backup_name}&wt=json")"

  if [ "$http_code" = "200" ]; then
    _log "Core '$core' backup initiated (HTTP 200)"
  else
    _log "ERROR: Core '$core' backup failed (HTTP $http_code)"
    return 1
  fi
}

_load_admin_creds
mkdir -p "$BACKUP_DIR"

if [ ! -f "$TENANTS_ENV" ]; then
  _log "WARNING: tenants.env not found at $TENANTS_ENV — no cores to back up"
  exit 0
fi

_log "=== Starting backup for all tenant cores ==="

CORES_BACKED_UP=0
while IFS='=' read -r key value; do
  case "$key" in
    TENANT_*_CORES)
      IFS=',' read -ra CORE_ARRAY <<< "$value"
      for core in "${CORE_ARRAY[@]}"; do
        core="$(echo "$core" | tr -d ' ')"
        [ -z "$core" ] && continue
        if backup_core "$core"; then
          ((CORES_BACKED_UP++)) || true
        fi
      done
      ;;
  esac
done < "$TENANTS_ENV"

_log "=== Backup complete: ${CORES_BACKED_UP} core(s) ==="
