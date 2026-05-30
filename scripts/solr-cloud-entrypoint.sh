#!/bin/bash
# Copyright (c) 2026 Eledia GmbH / Bernd Schreistetter
# SPDX-License-Identifier: MIT
# Version: v3.0.1

# =========================================
# Solr runtime entrypoint
# Developer: BSC Bernd Schreistetter
# Company: Eledia.de
# Version: v3.0.1
# =========================================
# Standalone mode:
#   exec solr-foreground directly.
#
# SolrCloud mode:
#   On first start (empty volume), the entrypoint generates security.json
#   from the embedded template using SOLR_ADMIN_PASSWORD / SOLR_SUPPORT_PASSWORD.
#   It then uploads security.json to ZooKeeper immediately after Solr starts,
#   before Docker marks the container healthy.
#   On subsequent starts, the existing security.json is re-uploaded to ZK
#   (idempotent — ZK is reset on embedded-ZK restart).
#
#   The entrypoint also uploads the eLeDia-moodle-tenant configset to ZK
#   and runs solr-tenant.sh apply to recreate collections for active tenants.
# =========================================

set -euo pipefail

SOLR_PORT="${SOLR_PORT:-8983}"
SOLR_BASE="http://localhost:${SOLR_PORT}/solr"

# Official Solr embedded ZooKeeper uses client port SOLR_PORT + 1000.
# Keep ZK_HOST overrideable for external ZooKeeper or unusual deployments.
if [ -z "${ZK_HOST:-}" ]; then
  case "$SOLR_PORT" in
    ''|*[!0-9]*) ZK_HOST="localhost:9983" ;;
    *) ZK_HOST="localhost:$((SOLR_PORT + 1000))" ;;
  esac
fi

SECURITY_JSON="${SECURITY_JSON:-/var/solr/data/security.json}"
SECURITY_TEMPLATE="${SECURITY_TEMPLATE:-/opt/solr/security.json.template}"
APPLY_MARKER_FILE="${APPLY_MARKER_FILE:-/var/solr/data/.eledia-apply-required}"

log() {
  printf '[solr-entrypoint] %s\n' "$*"
}

# hash_solr_password: Produce a Solr BasicAuthPlugin-compatible credential string.
# Algorithm: base64(SHA256(SHA256(random_salt || password))) + " " + base64(salt)
# Args: $1 - plaintext password
hash_solr_password() {
  local pass="$1"
  local salt_file pass_file combined hash1 hash2
  salt_file="$(mktemp)"
  pass_file="$(mktemp)"
  combined="$(mktemp)"
  hash1="$(mktemp)"
  hash2="$(mktemp)"
  chmod 600 "$salt_file" "$pass_file" "$combined" "$hash1" "$hash2"
  openssl rand 32 > "$salt_file"
  printf '%s' "$pass" > "$pass_file"
  cat "$salt_file" "$pass_file" > "$combined"
  openssl dgst -sha256 -binary "$combined" > "$hash1"
  openssl dgst -sha256 -binary "$hash1" > "$hash2"
  local hash_b64 salt_b64
  hash_b64="$(base64 < "$hash2" | tr -d '\n\r')"
  salt_b64="$(base64 < "$salt_file" | tr -d '\n\r')"
  dd if=/dev/zero of="$pass_file" bs=1 count="$(wc -c < "$pass_file")" 2>/dev/null || true
  dd if=/dev/zero of="$combined"  bs=1 count="$(wc -c < "$combined")"  2>/dev/null || true
  rm -f "$salt_file" "$pass_file" "$combined" "$hash1" "$hash2"
  printf '%s %s' "$hash_b64" "$salt_b64"
}

# generate_security_json: Create /var/solr/data/security.json from template.
# Called when the file is missing (fresh volume / first start).
# Requires: SOLR_ADMIN_USER, SOLR_ADMIN_PASSWORD, SOLR_SUPPORT_USER, SOLR_SUPPORT_PASSWORD
generate_security_json() {
  log "Generating security.json from template (first start)"

  local admin_user="${SOLR_ADMIN_USER:-admin}"
  local support_user="${SOLR_SUPPORT_USER:-support}"

  if [ -z "${SOLR_ADMIN_PASSWORD:-}" ]; then
    log "ERROR: SOLR_ADMIN_PASSWORD is not set — cannot generate security.json"
    return 1
  fi
  if [ -z "${SOLR_SUPPORT_PASSWORD:-}" ]; then
    log "ERROR: SOLR_SUPPORT_PASSWORD is not set — cannot generate security.json"
    return 1
  fi
  if [ ! -f "$SECURITY_TEMPLATE" ]; then
    log "ERROR: security.json template not found at $SECURITY_TEMPLATE"
    return 1
  fi

  log "Hashing credentials..."
  local admin_hash support_hash
  admin_hash="$(hash_solr_password "$SOLR_ADMIN_PASSWORD")"
  support_hash="$(hash_solr_password "$SOLR_SUPPORT_PASSWORD")"

  mkdir -p "$(dirname "$SECURITY_JSON")"
  local tmp
  tmp="$(mktemp)"
  chmod 600 "$tmp"
  sed \
    -e "s|__ADMIN_USER__|${admin_user}|g" \
    -e "s|__SUPPORT_USER__|${support_user}|g" \
    -e "s|__ADMIN_HASH__|${admin_hash}|g" \
    -e "s|__SUPPORT_HASH__|${support_hash}|g" \
    "$SECURITY_TEMPLATE" > "$tmp"
  mv "$tmp" "$SECURITY_JSON"
  chmod 600 "$SECURITY_JSON"
  log "security.json generated at $SECURITY_JSON"
}

wait_for_solr() {
  local i code
  for i in $(seq 1 90); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "${SOLR_BASE}/admin/info/system" 2>/dev/null || true)"
    case "$code" in
      200|401|403) return 0 ;;
    esac
    sleep 1
  done
  log "ERROR: Solr API did not become reachable at ${SOLR_BASE}"
  return 1
}

wait_for_auth() {
  local i code
  for i in $(seq 1 30); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "${SOLR_BASE}/admin/authentication" 2>/dev/null || true)"
    if [ "$code" = "401" ]; then
      log "SolrCloud security active (anonymous /admin/authentication -> 401)"
      return 0
    fi
    sleep 1
  done
  log "ERROR: SolrCloud security did not become active after ZooKeeper upload"
  return 1
}

ensure_system_collection() {
  local admin_user admin_pass list_json create_json

  admin_user="${SOLR_ADMIN_USER:-admin}"
  admin_pass="${SOLR_ADMIN_PASSWORD:-}"
  if [ -z "$admin_pass" ]; then
    log "WARNING: SOLR_ADMIN_PASSWORD not set; cannot auto-create .system collection"
    return 0
  fi

  list_json="$(curl -sS -u "${admin_user}:${admin_pass}" \
    "${SOLR_BASE}/admin/collections?action=LIST&wt=json" 2>/dev/null || true)"

  if printf '%s' "$list_json" | jq -e '.collections[]? | select(.==".system")' >/dev/null 2>&1; then
    log "SolrCloud internal collection .system already present"
    return 0
  fi

  log "Creating missing SolrCloud internal collection .system (idempotent bootstrap)"
  create_json="$(curl -sS -u "${admin_user}:${admin_pass}" \
    "${SOLR_BASE}/admin/collections?action=CREATE&name=.system&numShards=1&replicationFactor=1&collection.configName=_default&wt=json" 2>/dev/null || true)"

  if printf '%s' "$create_json" | jq -e '.responseHeader.status == 0' >/dev/null 2>&1; then
    log "Created .system collection successfully"
    return 0
  fi

  if printf '%s' "$create_json" | grep -qi 'already exists'; then
    log ".system collection already exists (race-safe)"
    return 0
  fi

  log "WARNING: could not auto-create .system collection; schema designer may fail until created manually"
  log "WARNING: create response: $create_json"
  return 0
}

schema_designer_guardrails_hint() {
  log "Schema Designer hint: sample upload limit is 5MB; markdown (text/markdown) is not supported"
}

ensure_zk_max_cnxns_opt() {
  local max_cnxns="${ZK_MAX_CNXNS:-60}"
  case "$max_cnxns" in
    ''|*[!0-9]*)
      log "WARNING: ZK_MAX_CNXNS='$max_cnxns' invalid, falling back to 60"
      max_cnxns="60"
      ;;
  esac
  export SOLR_OPTS="${SOLR_OPTS:-} -Dzookeeper.maxCnxns=${max_cnxns}"
  log "Using embedded ZooKeeper maxCnxns=${max_cnxns}"
}

ensure_zk_max_cnxns_opt

bootstrap_cloud_security() {
  local code

  wait_for_solr

  code="$(curl -s -o /dev/null -w '%{http_code}' "${SOLR_BASE}/admin/authentication" 2>/dev/null || true)"
  if [ "$code" = "401" ]; then
    log "SolrCloud security already active"
    return 0
  fi

  # Generate security.json if missing (first start — empty volume)
  if [ ! -f "$SECURITY_JSON" ]; then
    generate_security_json || return 1
  fi

  log "Uploading ${SECURITY_JSON} to ZooKeeper ${ZK_HOST} as /security.json"
  /opt/solr/bin/solr zk cp "file:${SECURITY_JSON}" "zk:/security.json" -z "$ZK_HOST"

  wait_for_auth
}

# ── SolrCloud mode ────────────────────────────────────────────────────────────
if [ "${SOLR_MODE:-}" = "solrcloud" ]; then
  # Step 0: If running as root — fix volume permissions, generate security.json,
  # then re-exec as solr user via gosu (Debian/Ubuntu package gosu 1.14).
  # Docker named volumes are created owned by root; dropping to solr ensures
  # ZooKeeper can write to /var/solr/data.
  if [ "$(id -u)" = "0" ]; then
    log "Running as root — fixing /var/solr ownership and dropping to solr user"
    mkdir -p /var/solr/data /var/solr/logs
    chown -R solr:solr /var/solr

    if [ ! -f "$SECURITY_JSON" ]; then
      generate_security_json || exit 1
      chown solr:solr "$SECURITY_JSON"
    fi

    exec gosu solr "$0" "$@"
  fi

  # Running as solr user from here on.
  log "Starting SolrCloud on port ${SOLR_PORT} with embedded ZooKeeper ${ZK_HOST}"
  solr-foreground -c -DzkRun &
  solr_pid="$!"

  terminate() {
    log "Stopping Solr PID ${solr_pid}"
    kill -TERM "$solr_pid" 2>/dev/null || true
    wait "$solr_pid" 2>/dev/null || true
  }
  trap terminate TERM INT

  bootstrap_cloud_security
  ensure_system_collection
  schema_designer_guardrails_hint

  # Upload eLeDia-moodle-tenant configset to ZooKeeper so Collections API can use it.
  # Configset source: bind-mounted from ./eLeDia-config at /opt/solr/eledia-config
  # Fallback chain: eledia-config mount -> data/configsets/eLeDia-moodle-tenant -> legacy moodle-tenant
  if [ -d "/opt/solr/eledia-config" ]; then
    local_conf_dir="/opt/solr/eledia-config"
  elif [ -d "/var/solr/data/configsets/eLeDia-moodle-tenant/conf" ]; then
    local_conf_dir="/var/solr/data/configsets/eLeDia-moodle-tenant/conf"
  elif [ -d "/var/solr/data/configsets/moodle-tenant/conf" ]; then
    log "WARN: falling back to legacy moodle-tenant configset path"
    local_conf_dir="/var/solr/data/configsets/moodle-tenant/conf"
  else
    log "ERROR: no configset source found — checked /opt/solr/eledia-config, /var/solr/data/configsets/eLeDia-moodle-tenant/conf"
    exit 1
  fi
  log "Uploading eLeDia-moodle-tenant configset to ZooKeeper ${ZK_HOST} from ${local_conf_dir}"
  /opt/solr/bin/solr zk upconfig \
    -n eLeDia-moodle-tenant \
    -d "$local_conf_dir" \
    -z "$ZK_HOST" 2>&1 | while IFS= read -r line; do log "[zk] $line"; done

  apply_reason="startup"
  if [ -f "$APPLY_MARKER_FILE" ]; then
    apply_reason="init-change-detected"
  fi

  log "Applying tenant collections via solr-tenant.sh apply (reason: ${apply_reason})"
  (
    /opt/solr/scripts/solr-tenant.sh apply 2>&1
  ) | while IFS= read -r line; do log "[tenant] $line"; done || \
    log "WARNING: solr-tenant.sh apply returned non-zero — check tenant logs"

  log "Rebuilding tenant permission order after apply"
  (
    /opt/solr/scripts/solr-tenant.sh sync-sot 2>&1
  ) | while IFS= read -r line; do log "[tenant-sync] $line"; done || \
    log "WARNING: solr-tenant.sh sync-sot returned non-zero — check tenant logs"

  if [ -f "$APPLY_MARKER_FILE" ]; then
    rm -f "$APPLY_MARKER_FILE" || true
    log "Cleared init apply marker: $APPLY_MARKER_FILE"
  fi

  while kill -0 "$solr_pid" 2>/dev/null; do
    if [ -f "$APPLY_MARKER_FILE" ]; then
      log "Detected init apply marker during runtime — applying tenant collections"
      (
        /opt/solr/scripts/solr-tenant.sh apply 2>&1
      ) | while IFS= read -r line; do log "[tenant] $line"; done || \
        log "WARNING: runtime solr-tenant.sh apply returned non-zero — check tenant logs"

      rm -f "$APPLY_MARKER_FILE" || true
      log "Cleared init apply marker: $APPLY_MARKER_FILE"
    fi
    sleep 5
  done

  wait "$solr_pid"
else
  # ── Standalone mode ──────────────────────────────────────────────────────
  log "Starting standalone Solr on port ${SOLR_PORT}"
  exec solr-foreground
fi
