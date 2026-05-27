#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Validates API continuity for Moodle-facing access when switching
# Standalone <-> SolrCloud and back.

source .env
SOLR_PORT="${SOLR_PORT:-8983}"
ADMIN_PASS="${SOLR_ADMIN_PASSWORD:?SOLR_ADMIN_PASSWORD missing in .env}"
API_USER="${SOLR_MOODLE_USER:-admin}"
API_PASS="${SOLR_MOODLE_PASSWORD:-${SOLR_ADMIN_PASSWORD}}"

log() { printf '[mode-switch-test] %s\n' "$*"; }
fail() { printf '[mode-switch-test][FAIL] %s\n' "$*" >&2; exit 1; }

http_code() {
  curl -so /dev/null -w '%{http_code}' "$@"
}

wait_ready() {
  local waited=0
  while [ "$waited" -lt 120 ]; do
    local c
    c="$(http_code -u "admin:${ADMIN_PASS}" "http://127.0.0.1:${SOLR_PORT}/solr/admin/info/system")"
    [ "$c" = "200" ] && return 0
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}

assert_moodle_api_path() {
  local user="$1" pass="$2" core="$3"
  local c waited=0
  while [ "$waited" -lt 60 ]; do
    c="$(http_code -u "${user}:${pass}" "http://127.0.0.1:${SOLR_PORT}/solr/${core}/select?q=*:*&rows=0&wt=json")"
    [ "$c" = "200" ] && return 0
    sleep 3
    waited=$((waited + 3))
  done

  # Repair attempt after mode flip: re-apply tenant/core mappings once.
  local container tenant_cmd
  container="${INSTANCE_NAME:-solr}-solr"
  tenant_cmd="docker exec ${container} /opt/solr/scripts/solr-tenant.sh"
  $tenant_cmd apply >/dev/null 2>&1 || true

  waited=0
  while [ "$waited" -lt 30 ]; do
    c="$(http_code -u "${user}:${pass}" "http://127.0.0.1:${SOLR_PORT}/solr/${core}/select?q=*:*&rows=0&wt=json")"
    [ "$c" = "200" ] && return 0
    sleep 3
    waited=$((waited + 3))
  done

  docker compose logs --no-color solr | tail -n 80 >&2 || true
  return 1
}

ensure_eLeDia_core_exists() {
  local container="$1"
  local tenant_cmd="docker exec ${container} /opt/solr/scripts/solr-tenant.sh"
  $tenant_cmd create switch_ci --cores eLeDia_core >/dev/null 2>&1 || true
  $tenant_cmd enable switch_ci >/dev/null 2>&1 || true
}

log "Reset stack volumes for deterministic mode-switch test"
docker compose down -v >/dev/null 2>&1 || true

log "Start stack"
docker compose up -d --build
wait_ready || fail "Solr not ready in initial mode"
container="${INSTANCE_NAME:-solr}-solr"
ensure_eLeDia_core_exists "$container"

assert_moodle_api_path "$API_USER" "$API_PASS" "eLeDia_core" || fail "Moodle API failed in baseline"
log "Baseline API check OK"

log "Switch to SolrCloud"
./scripts/solr-mode-portability.sh switch --to solrcloud --no-build
wait_ready || fail "Solr not ready after switch to SolrCloud"
container="${INSTANCE_NAME:-solr}-solr"
ensure_eLeDia_core_exists "$container"
assert_moodle_api_path "$API_USER" "$API_PASS" "eLeDia_core"
log "API check after standalone -> solrcloud OK"

log "Switch back to standalone"
./scripts/solr-mode-portability.sh switch --to standalone --no-build
wait_ready || fail "Solr not ready after switch back to standalone"
container="${INSTANCE_NAME:-solr}-solr"
ensure_eLeDia_core_exists "$container"
assert_moodle_api_path "$API_USER" "$API_PASS" "eLeDia_core"
log "API check after solrcloud -> standalone OK"

log "PASS: Mode switch continuity validated"
