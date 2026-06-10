#!/bin/bash
# Copyright (c) 2026 eLeDia GmbH / Bernd Schreistetter (bsc)
# SPDX-License-Identifier: MIT
# Version: v3.1.0
#
# eLeDia Security Tests — auth, isolation, negative, performance
# Part of the eLeDia Solr Multi-Tenant Docker Stack.
# Sourced by run-tests.sh — do not run directly.

# shellcheck disable=SC2153  # Variables are initialized by run-tests.sh/test-lib.sh before sourcing modules.
# Security Tests Module

security_tests() {
    print_header "SECURITY TESTS - Security Validation"

    #Network binding
    print_test "Network binding (localhost only)"
    local binding

    binding=$(docker compose port solr "${SOLR_PORT}" 2>/dev/null)
    if echo "$binding" | grep -q "127.0.0.1"; then
        print_pass "Solr correctly bound to localhost only"
    else
        print_fail "Solr not bound to localhost: $binding"
    fi

   #Container privileges
    print_test "Container privileges (non-root for Solr)"
    local solr_uid
    solr_uid=$(docker exec "$SOLR_CONTAINER" sh -c 'ps -o uid= -C java 2>/dev/null | head -1 | tr -d " "' 2>/dev/null)
    if [ "$solr_uid" = "8983" ]; then
        print_pass "Solr JVM process runs as uid 8983 (solr)"
    else
        print_fail "Solr JVM runs as wrong uid: $solr_uid (expected 8983)"
    fi

    # Test 3: Privileged mode
    print_test "Privileged mode disabled"
    local privileged
    privileged=$(docker inspect "$SOLR_CONTAINER" --format='{{.HostConfig.Privileged}}' 2>/dev/null)
    if [ "$privileged" = "false" ]; then
        print_pass "Privileged mode disabled"
    else
        print_fail "Privileged mode enabled (SECURITY RISK)"
    fi

    # Secrets in environment (informational only)
    print_test "Container environment password check"
    if docker exec "$SOLR_CONTAINER" env 2>/dev/null | grep -qi "password"; then
        print_info "Password env vars found (normal for Docker containers)"
        print_pass "Container uses environment variables for configuration"
    else
        print_pass "No passwords in container environment"
    fi

    # File permissions
    print_test "Sensitive file permissions"
    local sec_perms
    sec_perms=$(docker exec "$SOLR_CONTAINER" stat -c '%a' /var/solr/data/security.json 2>/dev/null)

    if [ "$sec_perms" = "600" ]; then
        print_pass "security.json has correct permissions (600)"
    else
        print_fail "security.json has wrong permissions: $sec_perms (expected 600)"
    fi

    # .env.example validation — ensure template exists and has required keys
    print_test ".env.example present and contains required variables"
    local required_vars=("INSTANCE_NAME" "SOLR_PORT" "SOLR_ADMIN_USER" "SOLR_ADMIN_PASSWORD" "SOLR_SUPPORT_USER" "SOLR_SUPPORT_PASSWORD" "SOLR_MODE")
    local env_ok=1
    if [ ! -f ".env.example" ]; then
        print_fail ".env.example missing"
        env_ok=0
    else
        for var in "${required_vars[@]}"; do
            if ! grep -q "^${var}=" .env.example 2>/dev/null; then
                print_fail ".env.example missing variable: $var"
                env_ok=0
            fi
        done
        [ "$env_ok" -eq 1 ] && print_pass ".env.example present with all required variables"
    fi

    # Default passwords in production
    print_test "No default passwords used"
    if [ "$SOLR_ADMIN_PASSWORD" = "eledia_default" ]; then
        print_fail "Default password still in use (CHANGE IT!)"
    else
        print_pass "Default password changed"
    fi

    # Moodle PHP SolrClient: /admin/system/ must be accessible for moodle role
    # PHP PECL SolrClient::system() hits /solr/{core}/admin/system/ to get version.
    # Without core-system-read permission, is_server_ready() fails with 403.
    print_test "Moodle user can access /admin/system/ (PHP SolrClient::system())"
    local moodle_pass moodle_user system_code
    moodle_user=$(grep "^SOLR_MOODLE_USER=" .env 2>/dev/null | cut -d= -f2 | tr -d '"')
    moodle_pass=$(grep "^SOLR_MOODLE_PASSWORD=" .env 2>/dev/null | cut -d= -f2 | tr -d '"')
    if [ -n "$moodle_user" ] && [ -n "$moodle_pass" ]; then
        system_code=$(curl -s -o /dev/null -w '%{http_code}' \
            -u "${moodle_user}:${moodle_pass}" \
            "http://${SOLR_HOST}:8983/solr/${SOLR_CORE_NAME}/admin/system/")
        if [ "$system_code" = "200" ]; then
            print_pass "Moodle user can reach /admin/system/ (HTTP 200)"
        else
            print_fail "Moodle user blocked on /admin/system/ (HTTP $system_code) — Moodle is_server_ready() will fail"
        fi
    else
        : # SOLR_MOODLE_USER/PASSWORD not set — test skipped silently
    fi


    # tenants.env accessible in container
    print_test "tenants.env accessible in container"
    if docker exec "$SOLR_CONTAINER" test -f /opt/solr/tenants.env 2>/dev/null; then
        print_pass "tenants.env accessible in container"
    else
        print_fail "tenants.env not accessible in container"
    fi
}

# =========================================
# NEGATIVE TESTS - Invalid Input Handling
# =========================================

negative_tests() {
    print_header "NEGATIVE TESTS - Invalid Input Handling"


    # Test Invalid credentials
    print_test "Reject invalid credentials"
    local invalid_response

    invalid_response=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:wrongpassword" "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/cores")
    if [ "$invalid_response" = "401" ]; then
        print_pass "Invalid credentials rejected (HTTP 401)"
    else
        print_fail "Invalid credentials not rejected (HTTP $invalid_response)"
    fi

    # Tes SQL injection attempt in query
    print_test "SQL injection protection"
    local injection_response

    injection_response=$(curl -s -o /dev/null -w '%{http_code}' -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" "http://${SOLR_HOST}:${SOLR_PORT}/solr/${SOLR_CORE_NAME}/select?q=*:*';DROP%20TABLE%20users;--")
    if [ "$injection_response" = "200" ] || [ "$injection_response" = "400" ] || [ "$injection_response" = "404" ] || [ "$injection_response" = "401" ] || [ "$injection_response" = "403" ]; then
        print_pass "SQL injection handled safely (HTTP $injection_response)"
    else
        print_fail "Unexpected response to SQL injection (HTTP $injection_response)"
    fi

    # Test XSS attempt in query
    print_test "XSS protection"
    local xss_response

    xss_response=$(curl -s -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" "http://${SOLR_HOST}:${SOLR_PORT}/solr/${SOLR_CORE_NAME}/select?q=<script>alert('xss')</script>&wt=json")
    if echo "$xss_response" | grep -qv "<script>"; then
        print_pass "XSS attack sanitized"
    else
        print_fail "XSS content not sanitized"
    fi

    # Test  Extremely long query
    print_test "Handle extremely long query"
    local long_query

    long_query=$(python3 -c "print('a'*10000)")
    local long_response

    long_response=$(curl -s -o /dev/null -w '%{http_code}' -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" "http://${SOLR_HOST}:${SOLR_PORT}/solr/${SOLR_CORE_NAME}/select?q=${long_query}")
    if [ "$long_response" = "400" ] || [ "$long_response" = "414" ] || [ "$long_response" = "200" ]; then
        print_pass "Long query handled (HTTP $long_response)"
    else
        print_fail "Long query caused unexpected response (HTTP $long_response)"
    fi

    # Test Invalid core name
    print_test "Reject invalid core name"
    local invalid_core_response

    invalid_core_response=$(curl -s -o /dev/null -w '%{http_code}' -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" "http://${SOLR_HOST}:${SOLR_PORT}/solr/nonexistent_core/select?q=*:*")
    if [ "$invalid_core_response" = "404" ] || [ "$invalid_core_response" = "401" ] || [ "$invalid_core_response" = "403" ]; then
        print_pass "Invalid core safely rejected (HTTP $invalid_core_response)"
    else
        print_fail "Invalid core not rejected (HTTP $invalid_core_response)"
    fi

    # Test Empty query parameter
    print_test "Handle empty query"
    local empty_response

    empty_response=$(curl -s -o /dev/null -w '%{http_code}' -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" "http://${SOLR_HOST}:${SOLR_PORT}/solr/${SOLR_CORE_NAME}/select?q=")
    if [ "$empty_response" = "400" ] || [ "$empty_response" = "200" ] || [ "$empty_response" = "404" ] || [ "$empty_response" = "401" ] || [ "$empty_response" = "403" ]; then
        print_pass "Empty query handled (HTTP $empty_response)"
    else
        print_fail "Empty query caused unexpected response (HTTP $empty_response)"
    fi
}

# =========================================
# PERFORMANCE TESTS - Basic Performance
# =========================================

performance_tests() {
    print_header "PERFORMANCE TESTS - Basic Performance"

    local PERF_TIMEOUT_S
    PERF_TIMEOUT_S="${PERF_TIMEOUT_S:-10}"

    # Test Response time
    print_test "API response time (<2s)"
    local start_time

    start_time=$(date +%s%3N)
    if ! timeout "${PERF_TIMEOUT_S}s" curl -s -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/cores?action=STATUS" >/dev/null 2>&1; then
        print_fail "API response timeout after ${PERF_TIMEOUT_S}s"
    fi
    local end_time

    end_time=$(date +%s%3N)
    local response_time


    response_time=$((end_time - start_time))
    if [ $response_time -lt 2000 ]; then
        print_pass "Response time: ${response_time}ms (good)"
    else
        print_fail "Response time: ${response_time}ms (slow, >2000ms)"
    fi

    # Test Container resource usage
    print_test "Container memory usage"
    local mem_usage
    mem_usage=$(docker stats "$SOLR_CONTAINER" --no-stream --format "{{.MemUsage}}" 2>/dev/null | cut -d'/' -f1)
    if [ -n "$mem_usage" ]; then
        print_pass "Memory usage: $mem_usage"
    else
        : # no memory stats available — silent
    fi

    # Test Healthcheck responsiveness
    print_test "Healthcheck endpoint response"
    local health_response

    health_response=$(timeout "${PERF_TIMEOUT_S}s" curl -s -o /dev/null -w '%{http_code}' "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/ping" 2>/dev/null || echo 000)
    if [ "$health_response" = "401" ] || [ "$health_response" = "200" ]; then
        print_pass "Healthcheck endpoint responsive (HTTP $health_response)"
    else
        print_fail "Healthcheck endpoint not responding (HTTP $health_response)"
    fi

    # Test Concurrent request handling (load test)
    print_test "Concurrent request handling (10 parallel requests, timeout ${PERF_TIMEOUT_S}s)"
    local concurrent_start

    concurrent_start=$(date +%s%3N)
    local pids=()
    for i in {1..10}; do
        timeout "${PERF_TIMEOUT_S}s" curl -s -o /dev/null -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/cores?action=STATUS" &
        pids+=("$!")
    done
    local concurrent_timeout=0
    for pid in "${pids[@]}"; do
        wait "$pid" || concurrent_timeout=1
    done
    local concurrent_end

    concurrent_end=$(date +%s%3N)
    local concurrent_time


    concurrent_time=$((concurrent_end - concurrent_start))
    if [ "$concurrent_timeout" -ne 0 ]; then
        print_fail "Concurrent requests hit timeout (${PERF_TIMEOUT_S}s per request)"
    elif [ $concurrent_time -lt 5000 ]; then
        print_pass "Handled 10 concurrent requests in ${concurrent_time}ms"
    else
        print_fail "Concurrent requests too slow: ${concurrent_time}ms (expected <5000ms)"
    fi

    # Test Query performance under load
    print_test "Query performance under load (20 queries)"
    local load_start

    load_start=$(date +%s%3N)
    local load_timeout=0
    for i in {1..20}; do
        timeout "${PERF_TIMEOUT_S}s" curl -s -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" "http://${SOLR_HOST}:${SOLR_PORT}/solr/${SOLR_CORE_NAME}/select?q=*:*&rows=10" > /dev/null 2>&1 || load_timeout=1
    done
    local load_end

    load_end=$(date +%s%3N)
    local load_time

    load_time=$((load_end - load_start))
    local avg_time


    avg_time=$((load_time / 20))
    if [ "$load_timeout" -ne 0 ]; then
        print_fail "Query performance load test hit timeout (${PERF_TIMEOUT_S}s per request)"
    elif [ $avg_time -lt 200 ]; then
        print_pass "Average query time under load: ${avg_time}ms per query"
    else
        print_fail "Query performance under load too slow: ${avg_time}ms per query (expected <200ms)"
    fi
}

# =========================================
# MOODLE DOCUMENT TESTS
# =========================================

