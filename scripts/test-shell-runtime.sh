#!/bin/bash
# Copyright (c) 2026 eLeDia.de / Bernd Schreistetter (bsc)
# Version: v3.4.12
#
# Local runtime smoke tests for shell entrypoints.
# Executes scripts with safe local inputs and validates their responses.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORK_DIR="$(mktemp -d /tmp/eledia-shell-runtime.XXXXXX)"
PASS_COUNT=0
FAIL_COUNT=0
RUN_CAPTURE_OUT=""

cleanup() {
  rm -rf "$WORK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '[PASS] %s\n' "$*" >&2; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '[FAIL] %s\n' "$*" >&2; }

run_capture() {
  local label="$1" expected_rc="$2"
  shift 2
  local out rc
  out="$WORK_DIR/${label//[^a-zA-Z0-9_.-]/_}.out"
  set +e
  "$@" >"$out" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq "$expected_rc" ]; then
    pass "$label exited $rc"
  else
    fail "$label expected exit $expected_rc, got $rc"
    sed -n '1,120p' "$out" | sed 's/^/  | /'
  fi
  RUN_CAPTURE_OUT="$out"
}

assert_contains() {
  local label="$1" file="$2" pattern="$3"
  if grep -Eq "$pattern" "$file"; then
    pass "$label contains /$pattern/"
  else
    fail "$label missing /$pattern/"
    sed -n '1,120p' "$file" | sed 's/^/  | /'
  fi
}

assert_not_contains() {
  local label="$1" file="$2" pattern="$3"
  if grep -Eq "$pattern" "$file"; then
    fail "$label unexpectedly contains /$pattern/"
    sed -n '1,120p' "$file" | sed 's/^/  | /'
  else
    pass "$label does not contain /$pattern/"
  fi
}

copy_repo_workspace() {
  local dest="$1"
  mkdir -p "$dest"
  rsync -a \
    --exclude '.git/' \
    --exclude '.env.backup.*' \
    --exclude 'apache/generated/' \
    --exclude 'solr_data*/' \
    "$ROOT_DIR/" "$dest/"
}

test_generate_test_tenants() {
  local out log
  out="$WORK_DIR/tenants-7.env"
  run_capture generate-test-tenants 0 "$ROOT_DIR/scripts/generate-test-tenants.sh" 7 "$out"
  log="$RUN_CAPTURE_OUT"
  assert_contains "generate-test-tenants summary" "$log" 'Done: 7 tenants'
  if [ "$(grep -c '^TENANT_.*_CORES=' "$out")" -eq 7 ]; then
    pass "generate-test-tenants wrote 7 tenant records"
  else
    fail "generate-test-tenants record count mismatch"
  fi
}

test_apache_generator() {
  local ws log generated
  ws="$WORK_DIR/apache-workspace"
  copy_repo_workspace "$ws"
  run_capture apache-help 0 "$ws/apache/generate-apache-config.sh" --help
  log="$RUN_CAPTURE_OUT"
  assert_contains "apache --help" "$log" 'Usage:'
  run_capture apache-generate 0 "$ws/apache/generate-apache-config.sh" --instance smoke --hostname solr-smoke.example.test --port 19080 --email admin@example.test
  log="$RUN_CAPTURE_OUT"
  assert_contains "apache generate" "$log" 'Configuration generated:'
  generated="$ws/apache/generated/solr-smoke.conf"
  if [ -f "$generated" ] && grep -q 'solr-smoke.example.test' "$generated" && grep -q '19080' "$generated"; then
    pass "apache generated config contains hostname and port"
  else
    fail "apache generated config invalid"
  fi
  run_capture apache-invalid-port 1 "$ws/apache/generate-apache-config.sh" --instance smoke --hostname solr-smoke.example.test --port 80
  log="$RUN_CAPTURE_OUT"
  assert_contains "apache invalid port" "$log" 'Invalid port number'
}

test_backup_empty_tenants() {
  local tenants log backup_dir log_file
  tenants="$WORK_DIR/empty-tenants.env"
  backup_dir="$WORK_DIR/backup"
  log_file="$WORK_DIR/backup.log"
  : > "$tenants"
  SOLR_ADMIN_PASSWORD=secret TENANTS_ENV="$tenants" BACKUP_DIR="$backup_dir" LOG_FILE="$log_file" run_capture solr-backup-empty 0 "$ROOT_DIR/scripts/solr-backup.sh"
  log="$RUN_CAPTURE_OUT"
  assert_contains "solr-backup empty" "$log" 'Backup complete: 0 core'
}

test_upgrade_dry_run() {
  local ws legacy mig log
  ws="$WORK_DIR/upgrade-workspace"
  legacy="$WORK_DIR/legacy-solr"
  mig="$WORK_DIR/migration"
  copy_repo_workspace "$ws"
  mkdir -p "$legacy/coreA/conf" "$mig"
  printf 'name=coreA\n' > "$legacy/coreA/core.properties"
  cp "$ws/.env.example" "$ws/.env"
  sed -i \
    -e 's/^INSTANCE_NAME=.*/INSTANCE_NAME=env_instance_should_not_win/' \
    -e 's/^SOLR_ADMIN_PASSWORD=.*/SOLR_ADMIN_PASSWORD=adminpass/' \
    -e 's/^SOLR_SUPPORT_PASSWORD=.*/SOLR_SUPPORT_PASSWORD=supportpass/' \
    "$ws/.env"
  run_capture upgrade-dry-run 0 "$ws/scripts/upgrade-docker.sh" --dry-run --instance cli_instance_should_win --legacy-solr-home "$legacy" --migration-root "$mig"
  log="$RUN_CAPTURE_OUT"
  assert_contains "upgrade dry-run instance" "$log" 'instance:cli_instance_should_win'
  assert_not_contains "upgrade dry-run no env override" "$log" 'env_instance_should_not_win'
  assert_contains "upgrade dry-run import plan" "$log" 'Would import core directory into Docker volume solr_data_cli_instance_should_win: coreA'
}

test_create_moodle_fixtures() {
  local ws log
  ws="$WORK_DIR/fixtures-workspace"
  copy_repo_workspace "$ws"
  run_capture create-moodle-fixtures 0 "$ws/tests/create-moodle-fixtures.sh"
  log="$RUN_CAPTURE_OUT"
  assert_contains "create fixtures" "$log" 'Fixtures generated in'
  for f in fixture-notes.txt fixture-course-overview.html fixture-gradebook.csv fixture-announcement.rtf; do
    if [ -s "$ws/tests/$f" ]; then
      pass "fixture exists: $f"
    else
      fail "fixture missing or empty: $f"
    fi
  done
}

test_setup_isolated_stack() {
  if [ "${SKIP_SETUP_RUNTIME:-0}" = "1" ]; then
    pass "setup isolated stack skipped by SKIP_SETUP_RUNTIME=1"
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    pass "setup isolated stack skipped: docker not available"
    return 0
  fi
  local ws instance port log
  ws="$WORK_DIR/setup-workspace"
  instance="sh-runtime-$$"
  port="19191"
  copy_repo_workspace "$ws"
  cp "$ws/.env.example" "$ws/.env"
  sed -i \
    -e "s/^INSTANCE_NAME=.*/INSTANCE_NAME=${instance}/" \
    -e "s/^SOLR_PORT=.*/SOLR_PORT=${port}/" \
    -e 's/^SOLR_MODE=.*/SOLR_MODE=standalone/' \
    -e "s|^ELEDIA_LOG_ROOT=.*|ELEDIA_LOG_ROOT=${WORK_DIR}/logs|" \
    -e 's/^SOLR_ADMIN_PASSWORD=.*/SOLR_ADMIN_PASSWORD=adminpassruntime/' \
    -e 's/^SOLR_SUPPORT_PASSWORD=.*/SOLR_SUPPORT_PASSWORD=supportpassruntime/' \
    "$ws/.env"
  set +e
  printf '\n\n' | (cd "$ws" && LOG_ROOT="$WORK_DIR/logs" timeout 420 ./setup.sh) >"$WORK_DIR/setup.out" 2>&1
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    pass "setup.sh isolated stack completed"
    assert_contains "setup summary" "$WORK_DIR/setup.out" 'Setup Complete'
    if (cd "$ws" && SOLR_TEST_CONTAINER="${instance}-solr" SOLR_TEST_PREFIX="rtstand$$" ./scripts/test-tenant-commands.sh) >"$WORK_DIR/setup-command-matrix.out" 2>&1; then
      pass "tenant command matrix on setup stack"
      assert_contains "tenant matrix summary" "$WORK_DIR/setup-command-matrix.out" 'failed=0'
    else
      fail "tenant command matrix on setup stack failed"
      sed -n '1,160p' "$WORK_DIR/setup-command-matrix.out" | sed 's/^/  | /'
    fi
  else
    fail "setup.sh isolated stack failed with exit $rc"
    sed -n '1,200p' "$WORK_DIR/setup.out" | sed 's/^/  | /'
  fi
  (cd "$ws" && docker compose down -v >/dev/null 2>&1 || true)
}

test_unit_suite() {
  local log
  run_capture run-tests-unit 0 "$ROOT_DIR/scripts/run-tests.sh" --unit-only
  log="$RUN_CAPTURE_OUT"
  assert_contains "unit suite" "$log" 'TEST SUITE PASSED'
}

main() {
  printf 'Runtime shell smoke workspace: %s\n' "$WORK_DIR"
  test_generate_test_tenants
  test_apache_generator
  test_backup_empty_tenants
  test_upgrade_dry_run
  test_create_moodle_fixtures
  test_unit_suite
  test_setup_isolated_stack
  printf '\nShell runtime smoke summary: passed=%s failed=%s\n' "$PASS_COUNT" "$FAIL_COUNT"
  [ "$FAIL_COUNT" -eq 0 ]
}

main "$@"
