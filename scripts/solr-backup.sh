#!/bin/bash
# Copyright (c) 2026 eLeDia.de / Bernd Schreistetter (bsc)
# Version: v3.4.12

# =========================================
# Solr Backup — Multi-Tenant
# =========================================
# Backs up all cores/collections defined in tenants.env.
#   - Standalone : Replication API (/solr/<core>/replication?command=backup)
#                  and polls command=details until the snapshot completed.
#   - SolrCloud  : Collections API (action=BACKUP) — includes collection
#                  state; a replication-only copy of one replica is NOT a
#                  restorable SolrCloud backup.
# Cores shared by multiple tenants are deduplicated before backup.
# Run inside the solr container:
#   docker exec <container> /opt/solr/scripts/solr-backup.sh

set -euo pipefail

SOLR_BASE="${SOLR_BASE:-http://localhost:8983/solr}"
TENANTS_ENV="${TENANTS_ENV:-/opt/solr/tenants.env}"
BACKUP_DIR="${BACKUP_DIR:-/var/solr/data/backup}"
LOG_FILE="${LOG_FILE:-/var/log/solr/tenant.log}"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
# Max seconds to wait for a standalone snapshot to complete.
BACKUP_WAIT_TIMEOUT="${BACKUP_WAIT_TIMEOUT:-120}"

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

# _is_cloud_mode: True when the stack runs SolrCloud (SOLR_MODE=solrcloud).
_is_cloud_mode() {
  [ "${SOLR_MODE:-}" = "solrcloud" ]
}

# backup_core_standalone: Replication API backup for a single core, then poll
# command=details until the snapshot reports success (HTTP 200 only
# means "initiated", not "completed").
# Args: $1 - core name
# Returns: 0 when the snapshot completed successfully, 1 otherwise
backup_core_standalone() {
  local core="$1"
  local backup_name="${core}_${TIMESTAMP}"

  _log "Backing up core '$core' -> ${BACKUP_DIR}/${backup_name} (replication API)"

  local http_code
  http_code="$(curl -so /dev/null -w '%{http_code}' \
    -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "${SOLR_BASE}/${core}/replication?command=backup&location=${BACKUP_DIR}&name=${backup_name}&wt=json")"

  if [ "$http_code" != "200" ]; then
    _log "ERROR: Core '$core' backup request failed (HTTP $http_code)"
    return 1
  fi

  # Poll replication?command=details until the snapshot completed.
  # NamedList JSON may serialize .details.backup as an object or as a flat
  # ["key","value",...] array depending on Solr version — match textually.
  local waited=0 details backup_section
  while [ "$waited" -lt "$BACKUP_WAIT_TIMEOUT" ]; do
    details="$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" \
      "${SOLR_BASE}/${core}/replication?command=details&wt=json" 2>/dev/null || true)"
    backup_section="$(printf '%s' "$details" | jq -c '.details.backup // empty' 2>/dev/null || true)"
    if [ -n "$backup_section" ]; then
      if printf '%s' "$backup_section" | grep -q "$backup_name"; then
        if printf '%s' "$backup_section" | grep -qi '"success"'; then
          _log "Core '$core' backup completed (snapshot ${backup_name})"
          return 0
        fi
        if printf '%s' "$backup_section" | grep -qiE '"(failed|exception)"|snapshotError'; then
          _log "ERROR: Core '$core' backup failed (replication details: ${backup_section})"
          return 1
        fi
      fi
    fi
    sleep 3
    waited=$((waited + 3))
  done

  _log "ERROR: Core '$core' backup did not complete within ${BACKUP_WAIT_TIMEOUT}s"
  return 1
}

# backup_collection_cloud: Collections API backup for a single collection.
# Synchronous call — Solr returns after the backup finished or failed.
# Args: $1 - collection name
# Returns: 0 on success (responseHeader.status == 0), 1 on failure
backup_collection_cloud() {
  local collection="$1"
  local backup_name="${collection}_${TIMESTAMP}"

  _log "Backing up collection '$collection' -> ${BACKUP_DIR}/${backup_name} (Collections API)"

  local response rc_status
  response="$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "${SOLR_BASE}/admin/collections?action=BACKUP&name=${backup_name}&collection=${collection}&location=${BACKUP_DIR}&wt=json" 2>/dev/null || true)"
  rc_status="$(printf '%s' "$response" | jq -r '.responseHeader.status // 1' 2>/dev/null || printf '1')"

  if [ "$rc_status" = "0" ]; then
    _log "Collection '$collection' backup completed (${backup_name})"
    return 0
  fi

  local err_msg
  err_msg="$(printf '%s' "$response" | jq -r '.error.msg // "unknown error"' 2>/dev/null || printf 'unparseable response')"
  _log "ERROR: Collection '$collection' backup failed: ${err_msg}"
  return 1
}

# collect_cores: Print the deduplicated, sorted list of cores from tenants.env.
# Tenants may intentionally share a collection (supported since v3.4.8) —
# without dedup the same index would be backed up once per tenant.
collect_cores() {
  local key value core
  while IFS='=' read -r key value; do
    case "$key" in
      TENANT_*_CORES)
        IFS=',' read -ra CORE_ARRAY <<< "$value"
        for core in "${CORE_ARRAY[@]}"; do
          core="$(printf '%s' "$core" | tr -d ' ')"
          [ -n "$core" ] && printf '%s\n' "$core"
        done
        ;;
    esac
  done < "$TENANTS_ENV" | sort -u
}

_load_admin_creds
mkdir -p "$BACKUP_DIR"

if [ ! -f "$TENANTS_ENV" ]; then
  _log "WARNING: tenants.env not found at $TENANTS_ENV — no cores to back up"
  exit 0
fi

MODE_LABEL="standalone"
_is_cloud_mode && MODE_LABEL="solrcloud"
_log "=== Starting backup for all tenant cores (mode: ${MODE_LABEL}) ==="

CORES_BACKED_UP=0
CORES_FAILED=0
while IFS= read -r core; do
  [ -z "$core" ] && continue
  if _is_cloud_mode; then
    if backup_collection_cloud "$core"; then
      CORES_BACKED_UP=$((CORES_BACKED_UP + 1))
    else
      CORES_FAILED=$((CORES_FAILED + 1))
    fi
  else
    if backup_core_standalone "$core"; then
      CORES_BACKED_UP=$((CORES_BACKED_UP + 1))
    else
      CORES_FAILED=$((CORES_FAILED + 1))
    fi
  fi
done < <(collect_cores)

_log "=== Backup complete: ${CORES_BACKED_UP} succeeded, ${CORES_FAILED} failed ==="
if [ "$CORES_FAILED" -gt 0 ]; then
  exit 1
fi
