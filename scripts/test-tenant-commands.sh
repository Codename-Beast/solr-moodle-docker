#!/bin/bash
# Copyright (c) 2026 eLeDia.de / Bernd Schreistetter (bsc)
# Version: v3.4.9
#
# eLeDia tenant command matrix test.
# Exercises solr-tenant.sh commands against a running Solr container.

set -euo pipefail

CONTAINER="${SOLR_TEST_CONTAINER:-${1:-${INSTANCE_NAME:-solr}-solr}}"
PREFIX="${SOLR_TEST_PREFIX:-cmdtest}"
TENANT_A="${PREFIX}_a"
TENANT_B="${PREFIX}_b"
CORE_SHARED="${PREFIX}_shared"
CORE_A_EXTRA="${PREFIX}_extra"
DOMAIN="${SOLR_TEST_DOMAIN:-example.test}"

pass_count=0
fail_count=0

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
pass() { pass_count=$((pass_count + 1)); printf '[PASS] %s\n' "$*"; }
fail() { fail_count=$((fail_count + 1)); printf '[FAIL] %s\n' "$*"; }

run_tenant() {
  docker exec "$CONTAINER" /opt/solr/scripts/solr-tenant.sh "$@"
}

container_sh() {
  docker exec "$CONTAINER" bash -lc "$1"
}

get_tenant_field() {
  local tenant="$1" field="$2"
  container_sh "grep '^TENANT_${tenant}_${field}=' \"\${TENANTS_ENV:-/opt/solr/tenants.env}\" | cut -d= -f2-"
}

probe_code() {
  local user="$1" pass="$2" path="$3" method="${4:-GET}" data="${5:-}"
  if [ -n "$data" ]; then
    container_sh "curl -sS -o /tmp/tenant-command-probe.out -w '%{http_code}' -u \"${user}:${pass}\" -X '${method}' -H 'Content-Type: application/json' -d '${data}' \"http://localhost:\${SOLR_PORT:-8983}/solr${path}\" || true"
  else
    container_sh "curl -sS -o /tmp/tenant-command-probe.out -w '%{http_code}' -u \"${user}:${pass}\" -X '${method}' \"http://localhost:\${SOLR_PORT:-8983}/solr${path}\" || true"
  fi
}

probe_extract_code() {
  local user="$1" pass="$2" core="$3"
  container_sh "printf 'solr tika connectivity test\\n' > /tmp/_tenant_command_tika.txt; code=\$(curl -sS -o /tmp/tenant-command-probe.out -w '%{http_code}' -u \"${user}:${pass}\" -F 'file=@/tmp/_tenant_command_tika.txt' \"http://localhost:\${SOLR_PORT:-8983}/solr/${core}/update/extract?extractOnly=true&wt=json\" || true); rm -f /tmp/_tenant_command_tika.txt; printf '%s' \"\$code\""
}

assert_code() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$label (HTTP $actual)"
  else
    fail "$label expected HTTP $expected, got $actual"
  fi
}

cleanup_tenant() {
  local tenant="$1"
  run_tenant delete "$tenant" --force >/dev/null 2>&1 || true
}

main() {
  if ! docker exec "$CONTAINER" test -x /opt/solr/scripts/solr-tenant.sh; then
    printf 'Container %s does not provide /opt/solr/scripts/solr-tenant.sh\n' "$CONTAINER" >&2
    exit 1
  fi

  local mode
  # shellcheck disable=SC2016  # expanded inside the target container
  mode="$(container_sh 'printf "%s" "${SOLR_MODE:-standalone}"')"
  [ -z "$mode" ] && mode="standalone"
  log "Testing container=$CONTAINER mode=$mode prefix=$PREFIX"

  cleanup_tenant "$TENANT_A"
  cleanup_tenant "$TENANT_B"
  run_tenant apply >/dev/null 2>&1 || true

  if run_tenant list >/tmp/tenant-command-list.out; then pass 'list command'; else fail 'list command'; fi

  if run_tenant create "$TENANT_A" --cores "$CORE_SHARED" >/tmp/tenant-command-create-a.out; then pass 'create tenant A'; else fail 'create tenant A'; fi
  if run_tenant create "$TENANT_B" --cores "$CORE_SHARED" >/tmp/tenant-command-create-b.out; then pass 'create tenant B with shared core'; else fail 'create tenant B with shared core'; fi

  if run_tenant info "$TENANT_A" >/tmp/tenant-command-info.out; then pass 'info command'; else fail 'info command'; fi

  local user_a pass_a user_b pass_b code
  user_a="$(get_tenant_field "$TENANT_A" USER)"
  pass_a="$(get_tenant_field "$TENANT_A" PASS)"
  user_b="$(get_tenant_field "$TENANT_B" USER)"
  pass_b="$(get_tenant_field "$TENANT_B" PASS)"

  code="$(probe_code "$user_a" "$pass_a" "/${CORE_SHARED}/admin/ping")"
  assert_code 'tenant A ping shared core' 200 "$code"
  code="$(probe_code "$user_b" "$pass_b" "/${CORE_SHARED}/select?q=*:*&rows=0")"
  assert_code 'tenant B select shared core' 200 "$code"
  code="$(probe_code "$user_a" "$pass_a" "/${CORE_SHARED}/update?commit=true" POST '{"commit":{}}')"
  assert_code 'tenant A update shared core' 200 "$code"
  code="$(probe_extract_code "$user_a" "$pass_a" "$CORE_SHARED")"
  assert_code 'tenant A update/extract shared core' 200 "$code"
  code="$(probe_code "$user_a" "$pass_a" "/${CORE_SHARED}/schema")"
  assert_code 'tenant A schema shared core' 200 "$code"

  if run_tenant passwd "$TENANT_A" >/tmp/tenant-command-passwd.out; then pass 'passwd command'; else fail 'passwd command'; fi
  local old_pass_a="$pass_a"
  pass_a="$(get_tenant_field "$TENANT_A" PASS)"
  code="$(probe_code "$user_a" "$old_pass_a" "/${CORE_SHARED}/select?q=*:*&rows=0")"
  assert_code 'old password rejected after passwd' 401 "$code"
  code="$(probe_code "$user_a" "$pass_a" "/${CORE_SHARED}/select?q=*:*&rows=0")"
  assert_code 'new password works after passwd' 200 "$code"

  local explicit_pass_a="ExplicitTenantCommandPassword2026"
  local generated_pass_a="$pass_a"
  if run_tenant passwd "$TENANT_A" --password "$explicit_pass_a" >/tmp/tenant-command-passwd-explicit.out; then pass 'passwd --password command'; else fail 'passwd --password command'; fi
  pass_a="$(get_tenant_field "$TENANT_A" PASS)"
  if [ "$pass_a" = "$explicit_pass_a" ]; then pass 'tenants.env stores explicit passwd value'; else fail 'tenants.env does not store explicit passwd value'; fi
  code="$(probe_code "$user_a" "$generated_pass_a" "/${CORE_SHARED}/select?q=*:*&rows=0")"
  assert_code 'generated password rejected after explicit passwd' 401 "$code"
  code="$(probe_code "$user_a" "$explicit_pass_a" "/${CORE_SHARED}/select?q=*:*&rows=0")"
  assert_code 'explicit password works after passwd --password' 200 "$code"

  if run_tenant core-add "$TENANT_A" --core "$CORE_A_EXTRA" >/tmp/tenant-command-core-add.out; then pass 'core-add command'; else fail 'core-add command'; fi
  code="$(probe_code "$user_a" "$pass_a" "/${CORE_A_EXTRA}/select?q=*:*&rows=0")"
  assert_code 'tenant A select added core' 200 "$code"

  if [ "$mode" = "solrcloud" ]; then
    code="$(probe_code "$user_b" "$pass_b" "/${CORE_A_EXTRA}/select?q=*:*&rows=0")"
    assert_code 'tenant B denied tenant A extra core in SolrCloud' 403 "$code"
  else
    code="$(probe_code "$user_b" "$pass_b" "/${CORE_A_EXTRA}/select?q=*:*&rows=0")"
    if [ "$code" = "200" ]; then
      pass 'standalone direct Solr cross-core access documented (Caddy handles URL isolation)'
    else
      fail "standalone direct Solr cross-core access changed unexpectedly (HTTP $code)"
    fi
  fi

  if run_tenant core-remove "$TENANT_A" --core "$CORE_A_EXTRA" >/tmp/tenant-command-core-remove.out; then pass 'core-remove command'; else fail 'core-remove command'; fi
  if run_tenant apply >/tmp/tenant-command-apply.out; then pass 'apply command'; else fail 'apply command'; fi
  if run_tenant sync-sot >/tmp/tenant-command-sync-sot.out; then pass 'sync-sot command'; else fail 'sync-sot command'; fi
  if run_tenant drift-detect >/tmp/tenant-command-drift-detect.out 2>&1; then
    pass 'drift-detect command (no drift)'
  elif grep -q 'Runtime drift detected' /tmp/tenant-command-drift-detect.out; then
    pass 'drift-detect command (reported drift via non-zero exit)'
  else
    fail 'drift-detect command failed unexpectedly'
  fi
  if run_tenant drift-remediate >/tmp/tenant-command-drift-remediate.out; then pass 'drift-remediate command'; else fail 'drift-remediate command'; fi
  if run_tenant export >/tmp/tenant-command-export.out && grep -q "name: ${TENANT_A}" /tmp/tenant-command-export.out; then pass 'export command'; else fail 'export command'; fi
  if run_tenant caddy-config --domain "$DOMAIN" >/tmp/tenant-command-caddy.out && grep -q "${TENANT_A//_/-}.${DOMAIN}" /tmp/tenant-command-caddy.out; then pass 'caddy-config command'; else fail 'caddy-config command'; fi

  if run_tenant delete "$TENANT_A" --force >/tmp/tenant-command-delete.out; then pass 'delete command'; else fail 'delete command'; fi
  code="$(probe_code "$user_a" "$pass_a" "/${CORE_SHARED}/select?q=*:*&rows=0")"
  assert_code 'deleted tenant password rejected' 401 "$code"

  if run_tenant enable "$TENANT_A" >/tmp/tenant-command-enable.out; then pass 'enable command'; else fail 'enable command'; fi
  pass_a="$(get_tenant_field "$TENANT_A" PASS)"
  code="$(probe_code "$user_a" "$pass_a" "/${CORE_SHARED}/select?q=*:*&rows=0")"
  assert_code 'enabled tenant password works' 200 "$code"

  cleanup_tenant "$TENANT_A"
  cleanup_tenant "$TENANT_B"
  run_tenant apply >/dev/null 2>&1 || true

  printf '\nTenant command matrix summary: passed=%s failed=%s\n' "$pass_count" "$fail_count"
  [ "$fail_count" -eq 0 ]
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
