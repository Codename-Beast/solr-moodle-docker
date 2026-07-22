#!/bin/bash
# Copyright (c) 2026 eLeDia.de / Bernd Schreistetter (bsc)
# Version: v3.4.12

# =========================================
# Solr Restore — Multi-Tenant
# =========================================
# Restores a core/collection from a backup created by solr-backup.sh.
#   - Standalone : Replication API (command=restore) + restorestatus polling
#   - SolrCloud  : Collections API (action=RESTORE) into the same collection
#                  name — the existing collection must be deleted first,
#                  which this script does after explicit confirmation
#                  (or --force).
# Usage (inside the solr container):
#   solr-restore.sh <core_or_collection> [backup_name] [--force] [--list]
#   backup_name empty = latest backup for that core in $BACKUP_DIR

set -euo pipefail

SOLR_BASE="${SOLR_BASE:-http://localhost:8983/solr}"
BACKUP_DIR="${BACKUP_DIR:-/var/solr/data/backup}"
LOG_FILE="${LOG_FILE:-/var/log/solr/tenant.log}"
RESTORE_WAIT_TIMEOUT="${RESTORE_WAIT_TIMEOUT:-300}"

# _log: Write a timestamped [RESTORE] message to stdout and $LOG_FILE.
_log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] [RESTORE] %s\n' "$ts" "$*" | tee -a "$LOG_FILE"
}

# _read_env_key: Read one simple KEY=value assignment from an env file.
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

# _load_admin_creds: Load only whitelisted admin credentials (no sourcing).
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

_is_cloud_mode() {
  [ "${SOLR_MODE:-}" = "solrcloud" ]
}

# find_latest_backup: Print newest backup name for a core from $BACKUP_DIR.
# Backup names follow <core>_<YYYYMMDD_HHMMSS>; lexicographic sort works.
find_latest_backup() {
  local core="$1" latest=""
  # Standalone snapshots: snapshot.<name> directories; Cloud: <name> dirs.
  latest="$(find "$BACKUP_DIR" -maxdepth 1 -name "*${core}_[0-9]*" -printf '%f\n' 2>/dev/null \
    | sed 's/^snapshot\.//' | sort | tail -n1)"
  [ -n "$latest" ] || return 1
  printf '%s' "$latest"
}

# restore_standalone: Replication API restore + restorestatus polling.
restore_standalone() {
  local core="$1" backup_name="$2"

  _log "Restoring core '$core' from '${backup_name}' (replication API)"

  local http_code
  http_code="$(curl -so /dev/null -w '%{http_code}' \
    -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "${SOLR_BASE}/${core}/replication?command=restore&location=${BACKUP_DIR}&name=${backup_name}&wt=json")"
  if [ "$http_code" != "200" ]; then
    _log "ERROR: Restore request for core '$core' failed (HTTP $http_code)"
    return 1
  fi

  local waited=0 status
  while [ "$waited" -lt "$RESTORE_WAIT_TIMEOUT" ]; do
    status="$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" \
      "${SOLR_BASE}/${core}/replication?command=restorestatus&wt=json" 2>/dev/null \
      | jq -r '.restorestatus.status // empty' 2>/dev/null || true)"
    case "$status" in
      success)
        _log "Core '$core' restore completed from ${backup_name}"
        return 0 ;;
      failed)
        _log "ERROR: Core '$core' restore failed (restorestatus: failed)"
        return 1 ;;
    esac
    sleep 3
    waited=$((waited + 3))
  done
  _log "ERROR: Core '$core' restore did not complete within ${RESTORE_WAIT_TIMEOUT}s"
  return 1
}

# restore_cloud: Collections API RESTORE. The target collection must not
# exist — delete it first (explicit confirmation unless --force).
restore_cloud() {
  local collection="$1" backup_name="$2" force="$3"

  local list_resp
  list_resp="$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "${SOLR_BASE}/admin/collections?action=LIST&wt=json" 2>/dev/null || true)"
  if printf '%s' "$list_resp" | jq -e --arg c "$collection" '.collections | index($c)' >/dev/null 2>&1; then
    if [ "$force" != "1" ]; then
      printf 'Collection "%s" exists and must be deleted before restore.\n' "$collection" >&2
      printf 'Re-run with --force to delete and restore, or restore into a new name.\n' >&2
      return 1
    fi
    _log "Deleting existing collection '$collection' before restore (--force)"
    local del_status
    del_status="$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" \
      "${SOLR_BASE}/admin/collections?action=DELETE&name=${collection}&wt=json" 2>/dev/null \
      | jq -r '.responseHeader.status // 1' 2>/dev/null || printf '1')"
    if [ "$del_status" != "0" ]; then
      _log "ERROR: Could not delete existing collection '$collection'"
      return 1
    fi
  fi

  _log "Restoring collection '$collection' from '${backup_name}' (Collections API)"
  local response rc_status
  response="$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "${SOLR_BASE}/admin/collections?action=RESTORE&name=${backup_name}&collection=${collection}&location=${BACKUP_DIR}&wt=json" 2>/dev/null || true)"
  rc_status="$(printf '%s' "$response" | jq -r '.responseHeader.status // 1' 2>/dev/null || printf '1')"

  if [ "$rc_status" = "0" ]; then
    _log "Collection '$collection' restore completed from ${backup_name}"
    return 0
  fi
  local err_msg
  err_msg="$(printf '%s' "$response" | jq -r '.error.msg // "unknown error"' 2>/dev/null || printf 'unparseable response')"
  _log "ERROR: Collection '$collection' restore failed: ${err_msg}"
  return 1
}

usage() {
  printf 'Usage: solr-restore.sh <core_or_collection> [backup_name] [--force]\n'
  printf '       solr-restore.sh --list [core]\n'
  printf '\n'
  printf '  backup_name omitted = latest backup for that core in %s\n' "$BACKUP_DIR"
  printf '  --force             = SolrCloud: delete existing collection before restore\n'
  printf '  --list              = show available backups\n'
}

CORE=""
BACKUP_NAME=""
FORCE=0
LIST_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --list)  LIST_ONLY=1; shift ;;
    --help|-h) usage; exit 0 ;;
    -*) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    *)
      if [ -z "$CORE" ]; then CORE="$1"; else BACKUP_NAME="$1"; fi
      shift ;;
  esac
done

if [ "$LIST_ONLY" = "1" ]; then
  printf 'Available backups in %s:\n' "$BACKUP_DIR"
  find "$BACKUP_DIR" -maxdepth 1 -name "*${CORE:-}*" -printf '  %f\n' 2>/dev/null | sort || true
  exit 0
fi

[ -z "$CORE" ] && { usage >&2; exit 1; }

_load_admin_creds

if [ -z "$BACKUP_NAME" ]; then
  BACKUP_NAME="$(find_latest_backup "$CORE" || true)"
  if [ -z "$BACKUP_NAME" ]; then
    _log "ERROR: No backup found for '$CORE' in $BACKUP_DIR"
    exit 1
  fi
  _log "Using latest backup: $BACKUP_NAME"
fi

if _is_cloud_mode; then
  restore_cloud "$CORE" "$BACKUP_NAME" "$FORCE"
else
  restore_standalone "$CORE" "$BACKUP_NAME"
fi
