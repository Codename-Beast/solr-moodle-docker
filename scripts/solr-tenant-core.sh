#!/bin/bash
# Copyright (c) 2026 eLeDia GmbH / Bernd Schreistetter (bsc)
# SPDX-License-Identifier: MIT
# Version: v3.1.0
#
# eLeDia Solr Tenant Core — core/collection CRUD (standalone + SolrCloud)
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

# Core/Collection Operations Module — sourced by solr-tenant.sh

# --- _create_core ---
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
    local create_resp
    create_resp="$(_solr_api GET "/admin/cores?action=CREATE&name=${core}&configSet=moodle-tenant&wt=json" 2>/dev/null)" || true
    if echo "$create_resp" | grep -q '"status":0'; then
      _log "INFO" "Core '$core' created"
    elif echo "$create_resp" | grep -q "coreNodeName"; then
      # SolrCloud: coreNodeName missing for pre-existing standalone core dir.
      # The collection is created internally by Solr; verify it exists.
      _log "WARN" "Core '$core' CREATE returned coreNodeName error (stale dir) — verifying"
      if _core_exists "$core"; then
        _log "INFO" "Core '$core' exists after CREATE workaround"
      else
        _log "ERROR" "Core '$core' CREATE failed and core does not exist"
        return 1
      fi
    elif [ -n "$create_resp" ]; then
      _log "WARN" "Core '$core' CREATE returned non-standard response — verifying existence"
      if _core_exists "$core"; then
        _log "INFO" "Core '$core' exists"
      else
        _log "ERROR" "Core '$core' CREATE response: $create_resp"
        return 1
      fi
    else
      # Empty response: Solr may not have logged the error yet; verify existence
      sleep 2
      if _core_exists "$core"; then
        _log "INFO" "Core '$core' exists after CREATE"
      else
        _log "ERROR" "Core '$core' CREATE returned empty response and core not found"
        return 1
      fi
    fi
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

# --- _write_security ---
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

# --- _cloud_auth_api ---
_cloud_auth_api() {
  local payload="$1"
  _solr_api POST "/admin/authentication" "$payload" > /dev/null
}

# POST to /solr/admin/authorization (roles/permissions management)

# --- _cloud_authz_api ---
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


# --- _cloud_bootstrap_security ---
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


# --- _collection_exists ---
_collection_exists() {
  local name="$1"
  local resp
  resp="$(_solr_api GET "/admin/collections?action=LIST&wt=json" 2>/dev/null)"
  printf '%s' "$resp" | jq -e --arg n "$name" '.collections | index($n) != null' > /dev/null 2>&1
}

# Upload configset to ZooKeeper via built-in solr CLI.
# Runs inside the Solr container where /opt/solr/bin/solr is available.
# ZK must be running (i.e., Solr already started) when this is called.

# --- _ensure_configset_zk ---
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


# --- _create_collection ---
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

