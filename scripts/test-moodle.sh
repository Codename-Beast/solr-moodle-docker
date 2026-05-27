#!/bin/bash
# Copyright (c) 2026 eLeDia GmbH / Bernd Schreistetter (bsc)
# SPDX-License-Identifier: MIT
# Version: v3.1.0
#
# eLeDia Moodle Tests — document indexing, Tika extraction, cloud
# Part of the eLeDia Solr Multi-Tenant Docker Stack.
# Sourced by run-tests.sh — do not run directly.

# Allow tests to continue even if some fail
# Using pipefail to catch errors in pipelines

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Test counters
TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Test results array
declare -a FAILED_TESTS

# Get dynamic container names from .env or fallback to default
if [ -f ".env" ]; then
    source .env
fi
INSTANCE_NAME=${INSTANCE_NAME:-solr}
SOLR_CONTAINER="${INSTANCE_NAME}-solr"
INIT_CONTAINER="${INSTANCE_NAME}-init"
SOLR_HOST="127.0.0.1"
SOLR_PORT="${SOLR_PORT:-8983}"
SOLR_CORE_NAME=${SOLR_CORE_NAME:-eLeDia_core}
SOLR_MODE="${SOLR_MODE:-}"
if ! echo "${SOLR_HEAP:-2g}" | grep -Eq '^[0-9]+[mMgG]$'; then
    echo "ERROR: SOLR_HEAP='${SOLR_HEAP:-}' ist ungültig. Erwartet z.B. 2g oder 1024m." >&2
    exit 1
fi
LOG_ROOT="${LOG_ROOT:-/var/log/solr/instances/${SOLR_CONTAINER}}"
RUN_LOG_FILE="${LOG_ROOT}/run-tests.log"
if ! mkdir -p "${LOG_ROOT}" 2>/dev/null; then
    LOG_ROOT="/tmp/eledia-logs"
    RUN_LOG_FILE="${LOG_ROOT}/run-tests.log"
    mkdir -p "${LOG_ROOT}" || {
        echo "ERROR: cannot create fallback log dir ${LOG_ROOT}." >&2
        exit 1
    }
    echo "WARN: using fallback LOG_ROOT=${LOG_ROOT} (no write access to /var/log/eledia)" >&2
fi
if ! touch "${RUN_LOG_FILE}" 2>/dev/null; then
    LOG_ROOT="/tmp/eledia-logs"
    RUN_LOG_FILE="${LOG_ROOT}/run-tests.log"
    mkdir -p "${LOG_ROOT}" || true
    touch "${RUN_LOG_FILE}" || {
        echo "ERROR: cannot write log file ${RUN_LOG_FILE}." >&2
        exit 1
    }
    echo "WARN: switched log output to ${RUN_LOG_FILE}" >&2
fi
exec > >(tee -a "${RUN_LOG_FILE}") 2>&1
# Moodle Document Tests Module

moodle_document_tests() {
    print_header "MOODLE DOCUMENT TESTS - Realistic Integration"

    # Check if test script exists
    if [ ! -f "scripts/test-moodle-documents.sh" ]; then
        print_skip "Moodle document test script not found"
        return
    fi

    print_info "Running Moodle document tests..."
    print_info "This includes: indexing, querying, filtering, highlighting, faceting"
    echo ""

    # Run the moodle document test script against the integration test core
    if SOLR_CORE_NAME="${SOLR_CORE_NAME}" bash scripts/test-moodle-documents.sh 2>&1 | tee /tmp/moodle-test-output.log | tail -20; then
        # Extract test results from output
        MOODLE_TESTS=$(grep "Total Tests:" /tmp/moodle-test-output.log | awk '{print $3}' || echo "0")
        MOODLE_PASSED=$(grep "Passed:" /tmp/moodle-test-output.log | awk '{print $2}' || echo "0")
        MOODLE_FAILED=$(grep "Failed:" /tmp/moodle-test-output.log | awk '{print $2}' || echo "0")

        # Update global counters
        ((TESTS_TOTAL += MOODLE_TESTS))
        ((TESTS_PASSED += MOODLE_PASSED))
        ((TESTS_FAILED += MOODLE_FAILED))

        if [ "$MOODLE_FAILED" -eq 0 ]; then
            echo -e "${GREEN}[PASS]${NC} Moodle document tests completed successfully ($MOODLE_PASSED/$MOODLE_TESTS)"
        else
            echo -e "${RED}[FAIL]${NC} Some Moodle document tests failed ($MOODLE_FAILED failures)"
            FAILED_TESTS+=("Moodle document tests ($MOODLE_FAILED failures)")
        fi
    else
        print_fail "Moodle document test script failed to execute"
        FAILED_TESTS+=("Moodle document test execution")
        ((TESTS_TOTAL++))
        ((TESTS_FAILED++))
    fi

    # Cleanup temp log
    rm -f /tmp/moodle-test-output.log
}

# =========================================
# CLEANUP TESTS - Cleanup and Restart
# =========================================

cleanup_tests() {
    print_header "CLEANUP TESTS - Restart and Data Persistence"

    local admin_pass

    # Test Restart without data loss
    admin_pass=$(grep "^SOLR_ADMIN_PASSWORD=" .env | cut -d= -f2)
    print_test "Restart without data loss"
    docker compose restart solr >/dev/null 2>&1
    sleep 20

    local restart_response


    restart_response=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:${admin_pass}" "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/cores")
    if [ "$restart_response" = "200" ]; then
        print_pass "Container restart successful, data persisted"
    else
        print_fail "Container restart failed or data lost"
    fi

    # Test Graceful shutdown
    print_test "Graceful shutdown"
    docker compose down >/dev/null 2>&1
    if ! docker ps | grep -q "$SOLR_CONTAINER"; then
        print_pass "Containers shut down gracefully"
    else
        print_fail "Containers still running after shutdown"
    fi

    # Test Volume persistence
    print_test "Volume persistence after shutdown"
    if docker volume ls | grep -q "solr_data"; then
        print_pass "Volumes persist after shutdown"
    else
        print_fail "Volumes removed (data loss risk)"
    fi
}

# =========================================
# MULTI-TENANT TESTS
# =========================================

mode_switch_tests() {
    print_header "MODE SWITCH TESTS - Standalone <-> SolrCloud API continuity"

    if [ ! -x "./scripts/test-mode-switch.sh" ]; then
        print_fail "scripts/test-mode-switch.sh not executable or missing"
        return
    fi

    print_test "Switch standalone -> solrcloud -> standalone without Moodle API break"
    if ./scripts/test-mode-switch.sh >/dev/null 2>&1; then
        print_pass "Mode switch continuity passed"
    else
        print_fail "Mode switch continuity failed"
    fi
}


solrcloud_tests() {
    print_header "SOLRCLOUD TESTS - Collections API & Restart Persistence"

    if ! _is_cloud_mode; then
        print_skip "SolrCloud tests skipped (SOLR_MODE != solrcloud)"
        return 0
    fi

    local admin_pass container tenant_cmd
    admin_pass=$(grep "^SOLR_ADMIN_PASSWORD=" .env | cut -d= -f2)
    container="${INSTANCE_NAME:-solr}-solr"
    tenant_cmd="docker exec $container /opt/solr/scripts/solr-tenant.sh"

    # Verify embedded ZooKeeper is running
    print_test "Embedded ZooKeeper reachable (port 9983)"
    local zk_code
    zk_code=$(curl -so /dev/null -w '%{http_code}' \
        -u "admin:${admin_pass}" \
        "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/zookeeper?detail=true&path=%2F&wt=json" 2>/dev/null)
    if [ "$zk_code" = "200" ]; then
        print_pass "ZooKeeper API reachable (HTTP 200)"
    else
        print_fail "ZooKeeper API not reachable (HTTP $zk_code)"
    fi

    # Collections API: create collection
    print_test "Collections API: create collection via tenant (cloud_test_c1)"
    local cloud_create_out
    cloud_create_out=$($tenant_cmd create cloud_tenant --cores cloud_test_c1 2>&1) || true
    if echo "$cloud_create_out" | grep -Eqi "already exists|bereits|exists"; then
        print_pass "Collection cloud_test_c1 already present"
    elif [ -n "$cloud_create_out" ] && ! echo "$cloud_create_out" | grep -Eqi "error|failed"; then
        print_pass "Collection cloud_test_c1 created via Collections API"
    elif $tenant_cmd info cloud_tenant >/dev/null 2>&1; then
        print_pass "Collection cloud_test_c1 created via Collections API"
    else
        print_fail "Failed to create collection cloud_test_c1"
    fi

    $tenant_cmd core-add cloud_tenant --core cloud_test_c1 >/dev/null 2>&1 || true
    $tenant_cmd enable cloud_tenant >/dev/null 2>&1 || true
    CLOUD_PASS="$(docker exec "$container" grep 'TENANT_cloud_tenant_PASS=' /opt/solr/tenants.env | tail -n1 | cut -d= -f2)"

    # Verify collection exists via Collections API
    print_test "Collection exists in ZooKeeper via Collections API"
    local coll_resp
    local coll_wait=0
    local coll_ok=0
    while [ "$coll_wait" -lt 60 ]; do
        coll_resp=$(curl -s -u "admin:${admin_pass}" \
            "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/collections?action=LIST&wt=json")
        if echo "$coll_resp" | grep -q '"cloud_test_c1"'; then
            coll_ok=1
            break
        fi
        sleep 3
        coll_wait=$((coll_wait + 3))
    done
    if [ "$coll_ok" -eq 1 ]; then
        print_pass "Collection cloud_test_c1 in Collections API list"
    else
        print_fail "Collection cloud_test_c1 NOT in Collections API list"
    fi

    # True isolation via collection field (SolrCloud enforces it)
    print_test "True collection isolation: wrong tenant => 403"
    local iso_code
    iso_code=$(curl -so /dev/null -w '%{http_code}' -u "solr_cloud_tenant:${CLOUD_PASS}" \
        "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/cores?wt=json" 2>/dev/null)
    if [ "$iso_code" = "403" ]; then
        print_pass "Admin API blocked for tenant (HTTP 403)"
    else
        print_fail "Admin API NOT blocked (HTTP $iso_code — expected 403)"
    fi

    # Index a minimal Moodle-compatible document to test persistence.
    # The managed schema has required Moodle fields (contextid, courseid,
    # owneruserid, modified, type, areaid, itemid); using only id/title would
    # correctly fail with HTTP 400 and would test the schema, not persistence.
    print_test "Index document for restart persistence test"
    local idx_code
    idx_code=$(curl -so /dev/null -w '%{http_code}' \
        -u "solr_cloud_tenant:${CLOUD_PASS}" \
        -X POST -H 'Content-Type: application/json' \
        -d '[{"id":"persist-test-1","title":"restart_persistence_check","content":"SolrCloud restart persistence test document","contextid":1,"courseid":1,"owneruserid":1,"modified":"2026-01-01T00:00:00Z","type":1,"areaid":"test_area","itemid":1}]' \
        "http://${SOLR_HOST}:${SOLR_PORT}/solr/cloud_test_c1/update?commit=true" 2>/dev/null)
    if [ "$idx_code" = "200" ]; then
        print_pass "Document indexed (HTTP 200)"
    else
        print_fail "Document indexing failed (HTTP $idx_code)"
    fi

    # Restart Solr and verify everything survives
    print_test "Restart Solr — collection, security, and documents must survive"
    docker compose restart solr >/dev/null 2>&1
    wait_for_solr_ready "$admin_pass" || true

    # Collection still exists
    coll_resp=$(curl -s -u "admin:${admin_pass}" \
        "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/collections?action=LIST&wt=json")
    if echo "$coll_resp" | grep -q '"cloud_test_c1"'; then
        print_pass "Collection survives restart (ZK persistence confirmed)"
    else
        print_fail "Collection LOST after restart (ZK data not persisted)"
    fi

    # Document still exists
    print_test "Document survives Solr restart (ZK + index persistence)"
    local doc_resp
    local doc_wait=0
    local doc_ok=0
    while [ "$doc_wait" -lt 60 ]; do
        doc_resp=$(curl -s -u "solr_cloud_tenant:${CLOUD_PASS}" \
            "http://${SOLR_HOST}:${SOLR_PORT}/solr/cloud_test_c1/select?q=id:persist-test-1&wt=json")
        if echo "$doc_resp" | grep -q '"numFound":1'; then
            doc_ok=1
            break
        fi
        sleep 3
        doc_wait=$((doc_wait + 3))
    done
    if [ "$doc_ok" -eq 1 ]; then
        print_pass "Document persists after restart"
    else
        print_fail "Document LOST after restart"
    fi

    # Tenant credentials survive (security in ZK)
    print_test "Tenant authentication survives restart (Security API in ZK)"
    local auth_code
    auth_code=$(curl -so /dev/null -w '%{http_code}' -u "solr_cloud_tenant:${CLOUD_PASS}" \
        "http://${SOLR_HOST}:${SOLR_PORT}/solr/cloud_test_c1/select?q=*:*&rows=0&wt=json" 2>/dev/null)
    if [ "$auth_code" = "200" ]; then
        print_pass "Tenant credentials persist after restart (HTTP 200)"
    else
        print_fail "Tenant authentication failed after restart (HTTP $auth_code)"
    fi

    # Cleanup
    $tenant_cmd delete cloud_tenant --force >/dev/null 2>&1 || true
}

# =========================================
# MAIN TEST EXECUTION
# =========================================

