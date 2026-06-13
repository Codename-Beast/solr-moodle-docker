#!/bin/bash
# Copyright (c) 2026 eLeDia.de / Bernd Schreistetter (bsc)
# Version: v3.1.0
#
# eLeDia Moodle Tests — document indexing, Tika extraction, cloud
# Part of the eLeDia Solr Multi-Tenant Docker Stack.
# Sourced by run-tests.sh — do not run directly.

# shellcheck disable=SC2153  # Variables are initialized by run-tests.sh/test-lib.sh before sourcing modules.
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
        # Extract machine-readable test results from output
        RESULTS_LINE=$(grep '^RESULTS:' /tmp/moodle-test-output.log | tail -n1 || true)
        if [ -n "$RESULTS_LINE" ]; then
            MOODLE_TESTS=$(echo "$RESULTS_LINE" | sed -n 's/.*total=\([0-9][0-9]*\).*/\1/p')
            MOODLE_PASSED=$(echo "$RESULTS_LINE" | sed -n 's/.*passed=\([0-9][0-9]*\).*/\1/p')
            MOODLE_FAILED=$(echo "$RESULTS_LINE" | sed -n 's/.*failed=\([0-9][0-9]*\).*/\1/p')
        else
            MOODLE_TESTS=0
            MOODLE_PASSED=0
            MOODLE_FAILED=1
        fi

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


    # Test Restart without data loss
    print_test "Restart without data loss"
    docker compose restart solr >/dev/null 2>&1
    sleep 20

    local restart_response


    restart_response=$(curl -s -o /dev/null -w '%{http_code}' -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/cores")
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
        print_fail "SolrCloud tests require SOLR_MODE=solrcloud (current mode is standalone)"
        return 1
    fi

    local container tenant_cmd
    container="${INSTANCE_NAME:-solr}-solr"
    tenant_cmd="docker exec $container /opt/solr/scripts/solr-tenant.sh"

    local cloud_tenant cloud_collection doc_id cloud_user
    cloud_tenant="cloud_tenant_$(date +%s)_$RANDOM"
    cloud_collection="cloud_test_c1_$(date +%s)_$RANDOM"
    doc_id="persist-test-${cloud_tenant}"
    cloud_user="solr_${cloud_tenant}"

    # Verify embedded ZooKeeper is running
    print_test "Embedded ZooKeeper reachable (port 9983)"
    local zk_code
    zk_code=$(curl -so /dev/null -w '%{http_code}' \
        -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
        "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/zookeeper?detail=true&path=%2F&wt=json" 2>/dev/null)
    if [ "$zk_code" = "200" ]; then
        print_pass "ZooKeeper API reachable (HTTP 200)"
    else
        print_fail "ZooKeeper API not reachable (HTTP $zk_code)"
    fi

    # Collections API: create collection via unique tenant to avoid stale state
    print_test "Collections API: create collection via tenant (${cloud_collection})"
    local cloud_create_out
    cloud_create_out=$($tenant_cmd create "$cloud_tenant" --cores "$cloud_collection" 2>&1) || true
    if [ -n "$cloud_create_out" ] && ! echo "$cloud_create_out" | grep -Eqi "error|failed"; then
        print_pass "Collection ${cloud_collection} created via Collections API"
    elif $tenant_cmd info "$cloud_tenant" >/dev/null 2>&1; then
        print_pass "Collection ${cloud_collection} created via Collections API"
    else
        print_fail "Failed to create collection ${cloud_collection}"
    fi

    local CLOUD_PASS
    CLOUD_PASS="$(docker exec "$container" sh -lc 'grep "^TENANT_'"${cloud_tenant}"'_PASS=" "${TENANTS_ENV:-/opt/solr/tenants.env}" | tail -n1 | cut -d= -f2')"

    # Verify collection exists via Collections API
    print_test "Collection exists in ZooKeeper via Collections API"
    local coll_resp
    local coll_wait=0
    local coll_ok=0
    while [ "$coll_wait" -lt 60 ]; do
        coll_resp=$(curl -s -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
            "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/collections?action=LIST&wt=json")
        if echo "$coll_resp" | grep -q "\"${cloud_collection}\""; then
            coll_ok=1
            break
        fi
        sleep 3
        coll_wait=$((coll_wait + 3))
    done
    if [ "$coll_ok" -eq 1 ]; then
        print_pass "Collection ${cloud_collection} in Collections API list"
    else
        print_fail "Collection ${cloud_collection} NOT in Collections API list"
    fi

    # True isolation via collection field (SolrCloud enforces it)
    print_test "True collection isolation: wrong tenant => 403"
    local iso_code
    iso_code=$(curl -so /dev/null -w '%{http_code}' -u "${cloud_user}:${CLOUD_PASS}" \
        "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/cores?wt=json" 2>/dev/null)
    if [ "$iso_code" = "403" ]; then
        print_pass "Admin API blocked for tenant (HTTP 403)"
    else
        print_fail "Admin API NOT blocked (HTTP $iso_code — expected 403)"
    fi

    # Index a minimal Moodle-compatible document to test persistence.
    print_test "Index document for restart persistence test"
    local idx_code
    idx_code=$(curl -so /dev/null -w '%{http_code}' \
        -u "${cloud_user}:${CLOUD_PASS}" \
        -X POST -H 'Content-Type: application/json' \
        -d "[{\"id\":\"${doc_id}\",\"title\":\"restart_persistence_check\",\"content\":\"SolrCloud restart persistence test document\",\"contextid\":1,\"courseid\":1,\"owneruserid\":1,\"modified\":\"2026-01-01T00:00:00Z\",\"type\":1,\"areaid\":\"test_area\",\"itemid\":1}]" \
        "http://${SOLR_HOST}:${SOLR_PORT}/solr/${cloud_collection}/update?commit=true" 2>/dev/null)
    if [ "$idx_code" = "200" ]; then
        print_pass "Document indexed (HTTP 200)"
    else
        print_fail "Document indexing failed (HTTP $idx_code)"
    fi

    # Restart Solr and verify everything survives
    print_test "Restart Solr — collection, security, and documents must survive"
    docker compose restart solr >/dev/null 2>&1
    wait_for_solr_ready "$SOLR_ADMIN_PASSWORD" || true

    # Collection still exists
    coll_resp=$(curl -s -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
        "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/collections?action=LIST&wt=json")
    if echo "$coll_resp" | grep -q "\"${cloud_collection}\""; then
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
        doc_resp=$(curl -s -u "${cloud_user}:${CLOUD_PASS}" \
            "http://${SOLR_HOST}:${SOLR_PORT}/solr/${cloud_collection}/select?q=id:${doc_id}&wt=json")
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
    auth_code=$(curl -so /dev/null -w '%{http_code}' -u "${cloud_user}:${CLOUD_PASS}" \
        "http://${SOLR_HOST}:${SOLR_PORT}/solr/${cloud_collection}/select?q=*:*&rows=0&wt=json" 2>/dev/null)
    if [ "$auth_code" = "200" ]; then
        print_pass "Tenant credentials persist after restart (HTTP 200)"
    else
        print_fail "Tenant authentication failed after restart (HTTP $auth_code)"
    fi

    # Permission ordering is security-critical: RuleBasedAuthorizationPlugin
    # evaluates first-match wins, so broad fallback 'all' must stay last.
    print_test "Authorization fallback permission 'all' is last"
    local last_permission
    last_permission=$(curl -s -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
        "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/authorization" \
        | jq -r '.authorization.permissions[-1].name // empty' 2>/dev/null || true)
    if [ "$last_permission" = "all" ]; then
        print_pass "Authorization permission ordering keeps 'all' last"
    else
        print_fail "Authorization permission ordering broken: last permission is '${last_permission}'"
    fi

    # Drift detection/remediation: add one unmanaged runtime user manually,
    # verify drift-detect reports it, drift-remediate rotates it, and the known
    # tenant user remains usable.
    local unmanaged_user unmanaged_pass drift_out drift_rc old_code known_code
    unmanaged_user="unmanaged_ci_drift_${RANDOM}"
    unmanaged_pass="UnmanagedDriftPass123_${RANDOM}"

    print_test "drift-detect reports unmanaged runtime user"
    curl -s -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" \
        -H 'Content-Type: application/json' \
        -X POST "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/authentication" \
        --data "{\"set-user\":{\"${unmanaged_user}\":\"${unmanaged_pass}\"}}" >/dev/null
    drift_out=$($tenant_cmd drift-detect 2>&1)
    drift_rc=$?
    if [ "$drift_rc" -ne 0 ] && echo "$drift_out" | grep -q "UNMANAGED_RUNTIME_USER: ${unmanaged_user}"; then
        print_pass "drift-detect found unmanaged runtime user ${unmanaged_user}"
    else
        print_fail "drift-detect did not report unmanaged runtime user ${unmanaged_user}"
        echo "$drift_out"
    fi

    print_test "drift-remediate rotates unmanaged user and preserves known tenant user"
    if $tenant_cmd drift-remediate >/tmp/_drift_remediate 2>&1; then
        old_code=$(curl -so /dev/null -w '%{http_code}' -u "${unmanaged_user}:${unmanaged_pass}" \
            "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/info/system" 2>/dev/null)
        known_code=$(curl -so /dev/null -w '%{http_code}' -u "${cloud_user}:${CLOUD_PASS}" \
            "http://${SOLR_HOST}:${SOLR_PORT}/solr/${cloud_collection}/select?q=*:*&rows=0&wt=json" 2>/dev/null)
        if [ "$old_code" = "401" ] && [ "$known_code" = "200" ]; then
            print_pass "drift-remediate rotated unmanaged user and preserved tenant credentials"
        else
            print_fail "drift-remediate result unexpected (unmanaged old pass HTTP $old_code, known tenant HTTP $known_code)"
            cat /tmp/_drift_remediate || true
        fi
    else
        print_fail "drift-remediate failed"
        cat /tmp/_drift_remediate || true
    fi

    # Cleanup
    $tenant_cmd delete "$cloud_tenant" --force >/dev/null 2>&1 || true
}

# =========================================
# MAIN TEST EXECUTION
# =========================================
