#!/bin/bash
# Copyright (c) 2026 eLeDia GmbH / Bernd Schreistetter (bsc)
# SPDX-License-Identifier: MIT
# Version: v3.1.0
#
# eLeDia Integration Tests — tenant lifecycle, scale, isolation
# Part of the eLeDia Solr Multi-Tenant Docker Stack.
# Sourced by run-tests.sh — do not run directly.

# shellcheck disable=SC2153  # Variables are initialized by run-tests.sh/test-lib.sh before sourcing modules.
# Integration Tests Module

integration_tests() {
    print_header "INTEGRATION TESTS - System Level"

    # Container startup
    print_test "Container startup and health"
    docker compose down -v >/dev/null 2>&1 || true

    # Generate .env if not exists
    if [ ! -f ".env" ]; then
        print_info "Generating .env for tests..."
        ./setup.sh >/dev/null 2>&1 || true
    fi

    # Ensure tenants file is writable for solr user in containerized tests.
    touch tenants.env
    chmod 666 tenants.env

    docker compose up -d >/dev/null 2>&1

    local waited=0
    while [ $waited -lt 180 ]; do
        if curl -s -o /dev/null -w '%{http_code}' -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/info/system" | grep -q '^200$'; then
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done

    local mapped_port
    mapped_port=$(docker compose port solr "${SOLR_PORT}" 2>/dev/null | awk -F: '{print $NF}' | tail -n1)
    if echo "$mapped_port" | grep -Eq '^[0-9]{2,5}$'; then
        SOLR_PORT="$mapped_port"
    fi

    if curl -s -o /dev/null -w '%{http_code}' -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/info/system" | grep -q '^200$'; then
        print_pass "Containers started and healthy"
    else
        print_fail "Containers not healthy"
        docker compose ps
    fi

    # Runtime guard: tenant helper must be available inside Solr container
    print_test "Tenant helper script available in container"
    if docker exec "$SOLR_CONTAINER" test -x /opt/solr/scripts/solr-tenant.sh 2>/dev/null; then
        print_pass "solr-tenant.sh found at /opt/solr/scripts/solr-tenant.sh"
    else
        print_fail "solr-tenant.sh missing in container (/opt/solr/scripts/solr-tenant.sh)"
    fi

    # Runtime guard: tenants file must exist where helper expects it
    print_test "tenants.env available in container"
    if docker exec "$SOLR_CONTAINER" test -f /opt/solr/tenants.env 2>/dev/null; then
        print_pass "tenants.env found at /opt/solr/tenants.env"
    else
        print_fail "tenants.env missing in container (/opt/solr/tenants.env)"
    fi

    # Runtime guard: tests need write access for create/delete/password rotation.
    print_test "tenants.env writable in container"
    if docker exec "$SOLR_CONTAINER" test -w /opt/solr/tenants.env 2>/dev/null; then
        print_pass "tenants.env is writable for tenant lifecycle ops"
    else
        print_fail "tenants.env is not writable in container"
    fi

    # Create a test tenant so core-level tests have a valid core to work with
    print_info "Creating test tenant ci_test (core: ${SOLR_CORE_NAME})..."
    docker exec "$SOLR_CONTAINER" /opt/solr/scripts/solr-tenant.sh \
        create ci_test --cores "${SOLR_CORE_NAME}" >/dev/null 2>&1 || true
    sleep 2

    # Solr Core Creation
    print_test "Solr core/collection creation"
    if _is_cloud_mode; then
        if curl -s -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/collections?action=LIST&wt=json" | grep -q "\"${SOLR_CORE_NAME}\""; then
            print_pass "Collection exists (${SOLR_CORE_NAME})"
        else
            print_fail "Collection not found (${SOLR_CORE_NAME})"
        fi
    elif docker exec "$SOLR_CONTAINER" test -d "/var/solr/data/${SOLR_CORE_NAME}" 2>/dev/null; then
        print_pass "Core directory created (${SOLR_CORE_NAME})"
    else
        print_fail "Core directory not found (${SOLR_CORE_NAME})"
    fi

    #security.json creation
    print_test "security.json creation and permissions"
    if docker exec "$SOLR_CONTAINER" test -f /var/solr/data/security.json 2>/dev/null; then
        local perms

        perms=$(docker exec "$SOLR_CONTAINER" stat -c '%a' /var/solr/data/security.json 2>/dev/null)
        if [ "$perms" = "600" ]; then
            print_pass "security.json exists with correct permissions (600)"
        else
            print_fail "security.json has wrong permissions: $perms (expected 600)"
        fi
    else
        print_fail "security.json not created"
    fi

    #Authentication
    print_test "Basic authentication"
    local response

    response=$(curl -s -o /dev/null -w '%{http_code}' -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/cores")
    if [ "$response" = "200" ]; then
        print_pass "Authentication successful (HTTP 200)"
    else
        print_fail "Authentication failed (HTTP $response)"
    fi

    #Unauthorized access blocked
    print_test "Unauthorized access blocked"
    local unauth_response

    unauth_response=$(curl -s -o /dev/null -w '%{http_code}' "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/cores")
    if [ "$unauth_response" = "401" ]; then
        print_pass "Unauthorized access correctly blocked (HTTP 401)"
    else
        print_fail "Unauthorized access not blocked (HTTP $unauth_response)"
    fi

    #Core status API
    #Core/Collection status API
    print_test "Core/Collection status API"
    local core_response
    if _is_cloud_mode; then
        core_response=$(curl -s -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/collections?action=LIST&wt=json")
    else
        core_response=$(curl -s -u "${SOLR_ADMIN_USER}:${SOLR_ADMIN_PASSWORD}" "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/cores?action=STATUS&wt=json")
    fi
    if echo "$core_response" | grep -q "${SOLR_CORE_NAME}"; then
        print_pass "Core/Collection API returns ${SOLR_CORE_NAME}"
    else
        print_fail "Core/Collection API does not return ${SOLR_CORE_NAME}"
    fi

    # Tenant management lifecycle (create/deactivate/enable/core add/core remove)
    print_header "TENANT MANAGEMENT TESTS"

    local tenant_name
    tenant_name="ci_lifecycle_$(date +%s)_$RANDOM"
    local tenant_core_a="${SOLR_CORE_NAME}_a"
    local tenant_core_b="${SOLR_CORE_NAME}_b"

    print_test "Tenant create with two cores"
    if docker exec "$SOLR_CONTAINER" /opt/solr/scripts/solr-tenant.sh create "$tenant_name" --cores "${tenant_core_a},${tenant_core_b}" >/tmp/_tenant_create 2>&1; then
        sleep 3
        print_pass "Tenant created (${tenant_name})"
    else
        print_fail "Tenant create failed (${tenant_name})"
        cat /tmp/_tenant_create | while IFS= read -r line; do echo "] $line"; done
        cat /tmp/_tenant_create || true
    fi

    print_test "Tenant info contains both cores"
    TENANT_INFO=$(docker exec "$SOLR_CONTAINER" /opt/solr/scripts/solr-tenant.sh info "$tenant_name" 2>/dev/null || true)
    if echo "$TENANT_INFO" | grep -q "$tenant_core_a" && echo "$TENANT_INFO" | grep -q "$tenant_core_b"; then
        print_pass "Tenant info includes expected cores"
    else
        print_fail "Tenant info missing expected cores"
        echo "$TENANT_INFO"
    fi

    print_test "Tenant core-remove removes one core"
    if docker exec "$SOLR_CONTAINER" /opt/solr/scripts/solr-tenant.sh core-remove "$tenant_name" --core "$tenant_core_b" >/tmp/_tenant_core_remove 2>&1; then
        TENANT_INFO=$(docker exec "$SOLR_CONTAINER" /opt/solr/scripts/solr-tenant.sh info "$tenant_name" 2>/dev/null || true)
        if echo "$TENANT_INFO" | grep -q "$tenant_core_b"; then
            print_fail "core-remove executed but core still present"
            echo "$TENANT_INFO"
        else
            print_pass "core-remove removed ${tenant_core_b}"
        fi
    else
        print_fail "Tenant core-remove failed"
        cat /tmp/_tenant_core_remove || true
    fi

    print_test "Tenant core-add restores removed core"
    if docker exec "$SOLR_CONTAINER" /opt/solr/scripts/solr-tenant.sh core-add "$tenant_name" --core "$tenant_core_b" >/tmp/_tenant_core_add 2>&1; then
        TENANT_INFO=$(docker exec "$SOLR_CONTAINER" /opt/solr/scripts/solr-tenant.sh info "$tenant_name" 2>/dev/null || true)
        if echo "$TENANT_INFO" | grep -q "$tenant_core_b"; then
            print_pass "core-add restored ${tenant_core_b}"
        else
            print_fail "core-add executed but core not present"
            echo "$TENANT_INFO"
        fi
    else
        print_fail "Tenant core-add failed"
        cat /tmp/_tenant_core_add || true
    fi

    print_test "Tenant delete deactivates tenant"
    if docker exec "$SOLR_CONTAINER" /opt/solr/scripts/solr-tenant.sh delete "$tenant_name" --force >/tmp/_tenant_delete 2>&1; then
        TENANT_INFO=$(docker exec "$SOLR_CONTAINER" /opt/solr/scripts/solr-tenant.sh info "$tenant_name" 2>/dev/null || true)
        if echo "$TENANT_INFO" | grep -Eq "(Status:[[:space:]]*false|Active:[[:space:]]*false|TENANT_.*_ACTIVE=false)"; then
            print_pass "Tenant deactivated successfully"
        else
            print_fail "Tenant delete executed but ACTIVE flag not false"
            echo "$TENANT_INFO"
        fi
    else
        print_fail "Tenant delete failed"
        cat /tmp/_tenant_delete || true
    fi

    print_test "Tenant enable reactivates tenant"
    if docker exec "$SOLR_CONTAINER" /opt/solr/scripts/solr-tenant.sh enable "$tenant_name" >/tmp/_tenant_enable 2>&1; then
        TENANT_INFO=$(docker exec "$SOLR_CONTAINER" /opt/solr/scripts/solr-tenant.sh info "$tenant_name" 2>/dev/null || true)
        if echo "$TENANT_INFO" | grep -Eq "(Status:[[:space:]]*true|Active:[[:space:]]*true|TENANT_.*_ACTIVE=true)"; then
            print_pass "Tenant reactivated successfully"
        else
            print_fail "Tenant enable executed but ACTIVE flag not true"
            echo "$TENANT_INFO"
        fi
    else
        print_fail "Tenant enable failed"
        cat /tmp/_tenant_enable || true
    fi

    #Password change detection
    print_test "Password change detection"
    # Backup .env before modification
    cp .env .env.test_backup

    # Change password
    sed 's/^SOLR_ADMIN_PASSWORD=.*/SOLR_ADMIN_PASSWORD=TESTPASS999/' .env.test_backup > .env

    docker compose down >/dev/null 2>&1
    docker compose up -d >/dev/null 2>&1
    sleep 30

    if docker compose logs eLeDia-solr-init 2>&1 | grep -q "security.json written"; then
        print_pass "security.json regenerated on config change"
    else
        print_fail "security.json not regenerated"
    fi

    # Atomic restore of original .env
    mv .env.test_backup .env

    # Restart containers with restored password
    docker compose down >/dev/null 2>&1
    docker compose up -d >/dev/null 2>&1
    sleep 30
}

# =========================================
# SECURITY TESTS - Security Validation
# =========================================

tenant_tests() {
    print_header "MULTI-TENANT TESTS - Isolation & Management"
    local container="${INSTANCE_NAME:-solr}-solr"
    local tenant_cmd="docker exec $container /opt/solr/scripts/solr-tenant.sh"

    # Create tenant schule_a
    print_test "Create tenant schule_a (core: moodle_prod_a)"
    local create_out
    create_out=$($tenant_cmd create schule_a --cores moodle_prod_a 2>&1) || true
    if echo "$create_out" | grep -Eqi "already exists|bereits|exists"; then
        print_pass "Tenant schule_a already present"
    elif [ -n "$create_out" ] && ! echo "$create_out" | grep -Eqi "error|failed"; then
        print_pass "Tenant schule_a created"
    elif $tenant_cmd info schule_a >/dev/null 2>&1; then
        print_pass "Tenant schule_a created"
    else
        print_fail "Failed to create tenant schule_a"
    fi

    # Verify user via Security API (source of truth in SolrCloud)
    print_test "User solr_schule_a in Solr Security API"
    if docker exec "$container" sh -lc 'curl -s -u "$SOLR_ADMIN_USER:$SOLR_ADMIN_PASSWORD" \
        "http://localhost:${SOLR_PORT:-8983}/solr/admin/authentication" | jq -e ".authentication.credentials | has(\"solr_schule_a\")"' \
        2>/dev/null | grep -q true; then
        print_pass "User solr_schule_a present in Solr Security API"
    else
        print_fail "User solr_schule_a not found in Solr Security API"
    fi

    PASS_A="$(docker exec "$container" grep 'TENANT_schule_a_PASS=' /opt/solr/tenants.env | cut -d= -f2)"

    # Tenant can access own core
    print_test "solr_schule_a can access /moodle_prod_a/select (200)"
    local r
    r=$(curl -so /dev/null -w '%{http_code}' -u "solr_schule_a:${PASS_A}" \
        "http://${SOLR_HOST}:${SOLR_PORT}/solr/moodle_prod_a/select?q=*:*&rows=0" 2>/dev/null)
    if [ "$r" = "200" ]; then
        print_pass "Tenant access to own core: OK (HTTP 200)"
    else
        print_fail "Tenant access to own core failed (HTTP $r)"
    fi

    # Tenant blocked from admin API
    print_test "solr_schule_a CANNOT access /admin/cores (403)"
    r=$(curl -so /dev/null -w '%{http_code}' -u "solr_schule_a:${PASS_A}" \
        "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/cores" 2>/dev/null)
    if [ "$r" = "403" ]; then
        print_pass "Admin API correctly blocked for tenant (HTTP 403)"
    else
        print_fail "Admin API NOT blocked for tenant (HTTP $r — expected 403)"
    fi

    # Create tenant schule_b
    print_test "Create tenant schule_b (core: moodle_prod_b)"
    create_out=$($tenant_cmd create schule_b --cores moodle_prod_b 2>&1) || true
    if echo "$create_out" | grep -Eqi "already exists|bereits|exists"; then
        print_pass "Tenant schule_b already present"
    elif [ -n "$create_out" ] && ! echo "$create_out" | grep -Eqi "error|failed"; then
        print_pass "Tenant schule_b created"
    elif $tenant_cmd info schule_b >/dev/null 2>&1; then
        print_pass "Tenant schule_b created"
    else
        print_fail "Failed to create tenant schule_b"
    fi

    PASS_B="$(docker exec "$container" grep 'TENANT_schule_b_PASS=' /opt/solr/tenants.env | cut -d= -f2)"

    # Isolation: cross-core access enforcement depends on mode
    # SolrCloud: collection field enforced by Solr → 403
    # Standalone: collection field NOT enforced (SolrCloud-only limitation);
    #   isolation requires Caddy/proxy. Test verifies auth isolation (401/403) instead.
    if _is_cloud_mode; then
        print_test "ISOLATION (SolrCloud): solr_schule_a CANNOT access /moodle_prod_b/select (403)"
        r=$(curl -so /dev/null -w '%{http_code}' -u "solr_schule_a:${PASS_A}" \
            "http://${SOLR_HOST}:${SOLR_PORT}/solr/moodle_prod_b/select?q=*:*&rows=0" 2>/dev/null)
        if [ "$r" = "403" ]; then
            print_pass "SolrCloud isolation OK: schule_a cannot access schule_b (HTTP 403)"
        else
            print_fail "ISOLATION FAILURE: schule_a accessed schule_b (HTTP $r — expected 403)"
        fi
    else
        print_test "ISOLATION (standalone): authentication isolation — wrong password => 401"
        r=$(curl -so /dev/null -w '%{http_code}' -u "solr_schule_a:wrongpassword" \
            "http://${SOLR_HOST}:${SOLR_PORT}/solr/moodle_prod_a/select?q=*:*&rows=0" 2>/dev/null)
        if [ "$r" = "401" ]; then
            print_pass "Auth isolation OK: wrong password rejected (HTTP 401)"
        else
            print_fail "Auth isolation FAILED: wrong password not rejected (HTTP $r)"
        fi
        print_info "Note: URL-level core isolation requires Caddy proxy (run: solr-tenant.sh caddy-config)"
    fi

    # Support can read both cores
    print_test "support can read /moodle_prod_a/select (200)"
    local support_pass
    support_pass=$(grep "^SOLR_SUPPORT_PASSWORD=" .env | cut -d= -f2)
    r=$(curl -so /dev/null -w '%{http_code}' -u "support:${support_pass}" \
        "http://${SOLR_HOST}:${SOLR_PORT}/solr/moodle_prod_a/select?q=*:*&rows=0" 2>/dev/null)
    if [ "$r" = "200" ]; then
        print_pass "Support read access: OK (HTTP 200)"
    else
        print_fail "Support read access failed (HTTP $r)"
    fi

    # Support cannot write
    print_test "support CANNOT write to /moodle_prod_a/update (403)"
    r=$(curl -so /dev/null -w '%{http_code}' -u "support:${support_pass}" \
        -X POST -H 'Content-Type: application/json' -d '{"commit":{}}' \
        "http://${SOLR_HOST}:${SOLR_PORT}/solr/moodle_prod_a/update" 2>/dev/null)
    if [ "$r" = "403" ]; then
        print_pass "Support write correctly blocked (HTTP 403)"
    else
        print_fail "Support write NOT blocked (HTTP $r — expected 403)"
    fi

    # core-add
    print_test "core-add: add moodle_test_a to schule_a"
    if $tenant_cmd core-add schule_a --core moodle_test_a >/dev/null 2>&1; then
        print_pass "core-add successful"
    else
        print_fail "core-add failed"
    fi

    print_test "solr_schule_a can access /moodle_test_a/select (200)"
    r=$(curl -so /dev/null -w '%{http_code}' -u "solr_schule_a:${PASS_A}" \
        "http://${SOLR_HOST}:${SOLR_PORT}/solr/moodle_test_a/select?q=*:*&rows=0" 2>/dev/null)
    if [ "$r" = "200" ]; then
        print_pass "Access to new core: OK (HTTP 200)"
    else
        print_fail "Access to new core failed (HTTP $r)"
    fi

    # delete tenant
    print_test "delete schule_a -> login blocked (401)"
    $tenant_cmd delete schule_a --force >/dev/null 2>&1 || true
    r=$(curl -so /dev/null -w '%{http_code}' -u "solr_schule_a:${PASS_A}" \
        "http://${SOLR_HOST}:${SOLR_PORT}/solr/moodle_prod_a/select?q=*:*&rows=0" 2>/dev/null)
    if [ "$r" = "401" ]; then
        print_pass "Deleted tenant login correctly blocked (HTTP 401)"
    else
        print_fail "Deleted tenant can still login (HTTP $r — expected 401)"
    fi

    # enable tenant
    print_test "enable schule_a -> new password works (200)"
    NEW_PASS=$($tenant_cmd enable schule_a 2>/dev/null | grep 'Password:' | awk '{print $3}') || true
    if [ -z "$NEW_PASS" ]; then
        NEW_PASS="$(docker exec "$container" grep 'TENANT_schule_a_PASS=' /opt/solr/tenants.env | cut -d= -f2)"
    fi
    r=$(curl -so /dev/null -w '%{http_code}' -u "solr_schule_a:${NEW_PASS}" \
        "http://${SOLR_HOST}:${SOLR_PORT}/solr/moodle_prod_a/select?q=*:*&rows=0" 2>/dev/null)
    if [ "$r" = "200" ]; then
        print_pass "Re-enabled tenant login OK (HTTP 200)"
    else
        print_fail "Re-enabled tenant login failed (HTTP $r)"
    fi

    # apply (idempotent)
    print_test "apply is idempotent (no errors)"
    if $tenant_cmd apply >/dev/null 2>&1; then
        print_pass "apply completed without errors"
    else
        print_fail "apply returned errors"
    fi

    # Restart persistence
    print_test "Restart persistence: tenants survive docker compose restart"
    docker compose restart solr >/dev/null 2>&1 || true
    wait_for_solr_ready "$SOLR_ADMIN_PASSWORD" || true
    local rp_wait=0
    local rp_ok=0
    while [ "$rp_wait" -lt 60 ]; do
        if $tenant_cmd info schule_b 2>/dev/null | grep -Eqi "Tenant: schule_b|User:[[:space:]]+solr_schule_b"; then
            rp_ok=1
            break
        fi
        sleep 3
        rp_wait=$((rp_wait + 3))
    done
    if [ "$rp_ok" -eq 1 ]; then
        print_pass "Tenants persisted after restart"
    else
        print_fail "Tenants lost after restart"
    fi
}

# =========================================
# TENANT SCALE TESTS - Many Moodle Tenants
# =========================================

tenant_scale_tests() {
    print_header "TENANT SCALE TESTS - 30 Moodle tenants/cores/users"

    local container="${INSTANCE_NAME:-solr}-solr"
    local tenant_cmd="docker exec $container /opt/solr/scripts/solr-tenant.sh"
    local tenant_count=30
    local i tname cname tpass code created_ok=0

    print_test "Create ${tenant_count} tenants with dedicated cores"
    for i in $(seq 1 "$tenant_count"); do
        tname=$(printf 'moodle_%02d' "$i")
        cname=$(printf 'eLeDia_core_%02d' "$i")
        if $tenant_cmd create "$tname" --cores "$cname" >/dev/null 2>&1; then
            created_ok=$((created_ok + 1))
        fi
    done
    if [ "$created_ok" -eq "$tenant_count" ]; then
        print_pass "Created ${created_ok}/${tenant_count} tenants"
    else
        print_fail "Created only ${created_ok}/${tenant_count} tenants"
    fi

    print_test "All ${tenant_count} tenant credentials written to tenants.env"
    local cred_count
    cred_count=$(docker exec "$container" sh -lc "grep -c '^TENANT_moodle_[0-9][0-9]_PASS=' /opt/solr/tenants.env || true")
    if [ "$cred_count" -ge "$tenant_count" ]; then
        print_pass "tenants.env contains ${cred_count} tenant passwords"
    else
        print_fail "tenants.env contains only ${cred_count}/${tenant_count} tenant passwords"
    fi

    print_test "Sample tenant auth and core access work"
    tpass=$(docker exec "$container" sh -lc "grep '^TENANT_moodle_01_PASS=' /opt/solr/tenants.env | cut -d= -f2")
    code=$(curl -so /dev/null -w '%{http_code}' -u "solr_moodle_01:${tpass}" \
        "http://${SOLR_HOST}:${SOLR_PORT}/solr/eLeDia_core_01/select?q=*:*&rows=0" 2>/dev/null)
    if [ "$code" = "200" ]; then
        print_pass "Tenant solr_moodle_01 can access eLeDia_core_01"
    else
        print_fail "Tenant solr_moodle_01 cannot access eLeDia_core_01 (HTTP $code)"
    fi

    print_test "Wrong password for sample tenant is rejected"
    code=$(curl -so /dev/null -w '%{http_code}' -u "solr_moodle_01:wrong" \
        "http://${SOLR_HOST}:${SOLR_PORT}/solr/eLeDia_core_01/select?q=*:*&rows=0" 2>/dev/null)
    if [ "$code" = "401" ]; then
        print_pass "Wrong password rejected (HTTP 401)"
    else
        print_fail "Wrong password not rejected (HTTP $code)"
    fi

    print_test "Scale apply is idempotent"
    if $tenant_cmd apply >/dev/null 2>&1; then
        print_pass "apply completed successfully after scale create"
    else
        print_fail "apply failed after scale create"
    fi

    print_test "Cleanup scale tenants"
    local deleted_ok=0
    for i in $(seq 1 "$tenant_count"); do
        tname=$(printf 'moodle_%02d' "$i")
        if $tenant_cmd delete "$tname" --force >/dev/null 2>&1; then
            deleted_ok=$((deleted_ok + 1))
        fi
    done
    if [ "$deleted_ok" -eq "$tenant_count" ]; then
        print_pass "Deleted ${deleted_ok}/${tenant_count} scale tenants"
    else
        print_fail "Deleted only ${deleted_ok}/${tenant_count} scale tenants"
    fi
}

# =========================================
# SOLRCLOUD TESTS - Collections API + Persistence
# =========================================
# =========================================
# MODE SWITCH TESTS - Standalone <-> SolrCloud
# =========================================

