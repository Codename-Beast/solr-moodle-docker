#!/bin/bash
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
#   The init container writes /var/solr/data/security.json before Solr starts.
#   In SolrCloud, however, Solr reads security config from ZooKeeper, not from
#   the local filesystem. Embedded ZooKeeper only exists after Solr has started,
#   so we must bootstrap /security.json into ZK immediately after startup and
#   before Docker marks the container healthy.
#
# Why this script exists:
#   Without this bootstrap, SolrCloud starts with authentication=disabled even
#   though /var/solr/data/security.json exists. That makes admin APIs anonymous
#   until the first tenant command happens to upload security.json. Production
#   and tests both need security active as part of startup, not as a side effect.
# =========================================

set -euo pipefail

SOLR_PORT="${SOLR_PORT:-8983}"
SOLR_BASE="http://localhost:${SOLR_PORT}/solr"

# Official Solr embedded ZooKeeper uses client port SOLR_PORT + 1000.
# Keep ZK_HOST overrideable for external ZooKeeper or custom deployments.
if [ -z "${ZK_HOST:-}" ]; then
  case "$SOLR_PORT" in
    ''|*[!0-9]*) ZK_HOST="localhost:9983" ;;
    *) ZK_HOST="localhost:$((SOLR_PORT + 1000))" ;;
  esac
fi

SECURITY_JSON="${SECURITY_JSON:-/var/solr/data/security.json}"

log() {
  printf '[solr-entrypoint] %s\n' "$*"
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

bootstrap_cloud_security() {
  local code

  wait_for_solr

  code="$(curl -s -o /dev/null -w '%{http_code}' "${SOLR_BASE}/admin/authentication" 2>/dev/null || true)"
  if [ "$code" = "401" ]; then
    log "SolrCloud security already active"
    return 0
  fi

  if [ ! -f "$SECURITY_JSON" ]; then
    log "ERROR: ${SECURITY_JSON} not found; cannot bootstrap SolrCloud security"
    return 1
  fi

  log "Uploading ${SECURITY_JSON} to ZooKeeper ${ZK_HOST} as /security.json"
  /opt/solr/bin/solr zk cp "file:${SECURITY_JSON}" "zk:/security.json" -z "$ZK_HOST"

  wait_for_auth
}

if [ "${SOLR_MODE:-}" = "solrcloud" ]; then
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
  wait "$solr_pid"
else
  log "Starting standalone Solr on port ${SOLR_PORT}"
  exec solr-foreground
fi
