#!/bin/bash
# Copyright (c) 2026 eLeDia.de / Bernd Schreistetter (bsc)
# Version: v3.1.0
#
# eLeDia Unit Tests — file checks, compose config, Dockerfile
# Part of the eLeDia Solr Multi-Tenant Docker Stack.
# Sourced by run-tests.sh — do not run directly.

# shellcheck disable=SC2153  # Variables are initialized by run-tests.sh/test-lib.sh before sourcing modules.
# Unit Tests Module

unit_tests() {
    print_header "UNIT TESTS - Component Level"

    # Test 1: docker-compose.yml syntax
    print_test "docker-compose.yml syntax validation"
    if [ -f "docker-compose.yml" ] && grep -q "services:" docker-compose.yml; then
        print_pass "docker-compose.yml is valid"
    else
        print_fail "docker-compose.yml syntax error"
    fi

    #Required files exist
    print_test "Required files existence"
    local required_files=(
        "docker-compose.yml"
        "security.json.template"
        "eLeDia-config/managed-schema"
        "eLeDia-config/solrconfig.xml"
        "scripts/solr-cloud-entrypoint.sh"
        "scripts/solr-tenant.sh"
        "scripts/test-tenant-commands.sh"
        "tenants.env.example"
    )
    local missing=0
    for file in "${required_files[@]}"; do
        if [ ! -f "$file" ]; then
            print_fail "Missing required file: $file"
            missing=1
        fi
    done
    if [ $missing -eq 0 ]; then
        print_pass "All required files present"
    fi

    # Test 3: Security template
    print_test "Security bootstrap template"
    if [ -f "security.json.template" ]; then
        print_pass "security.json.template present (embedded in image for first-start security bootstrap)"
    else
        print_fail "security.json.template missing"
    fi

    # Security API delete-permission requires numeric indexes; names are accepted
    # only syntactically and returned as embedded errorMessages by Solr.
    print_test "Tenant permission deletion uses numeric indexes"
    if grep -q -- '--argjson i .*delete-permission' scripts/solr-tenant-security.sh && \
       ! grep -q '_cloud_authz_api.*--arg [nx].*delete-permission' scripts/solr-tenant-security.sh && \
       ! grep -q '_cloud_authz_api.*delete-permission.:.all' scripts/solr-tenant-security.sh; then
        print_pass "Tenant permission cleanup deletes by numeric index"
    else
        print_fail "Tenant permission cleanup still deletes by name"
    fi

    # apply must rebuild tenant permissions before moving the fallback all rule to the end.
    print_test "SolrCloud apply rebuilds tenant permissions"
    if grep -A5 'if _is_cloud_mode; then' scripts/solr-tenant-cmd.sh | grep -q '_rebuild_tenant_permissions' && \
       grep -A6 'if _is_cloud_mode; then' scripts/solr-tenant-cmd.sh | grep -q '_ensure_all_permission_last'; then
        print_pass "SolrCloud apply rebuilds tenant permissions and then moves all last"
    else
        print_fail "SolrCloud apply does not rebuild tenant permissions before all fallback"
    fi

    # Container-first delivery: helper scripts must be baked into Solr image
    print_test "Dockerfile.solr embeds runtime helper scripts"
    if grep -q 'COPY --chown=solr:solr scripts/ /opt/solr/scripts/' Dockerfile.solr; then
        print_pass "Dockerfile.solr copies scripts into /opt/solr/scripts"
    else
        print_fail "Dockerfile.solr does not embed /opt/solr/scripts"
    fi

    # Compose must not require host script bind mount for runtime correctness
    print_test "docker-compose does not depend on /opt/solr/scripts bind mount"
    if grep -q '\./scripts:/opt/solr/scripts' docker-compose.yml; then
        print_fail "docker-compose still bind-mounts ./scripts into solr service"
    else
        print_pass "docker-compose runtime is image-based for /opt/solr/scripts"
    fi

    # Test 4: Environment variable template
    print_test ".env.example validation"
    if [ -f ".env.example" ]; then
        if grep -q "INSTANCE_NAME" .env.example && \
           grep -q "SOLR_ADMIN_PASSWORD" .env.example; then
            print_pass ".env.example contains required variables"
        else
            print_fail ".env.example missing required variables"
        fi
    else
        print_fail ".env.example not found"
    fi

    #Docker image availability
    print_test "Docker images availability"
    if docker image inspect alpine:3.20 >/dev/null 2>&1 && \
       docker image inspect solr:9.10.1 >/dev/null 2>&1; then
        print_pass "Required Docker images available locally"
    else
        print_skip "Docker images not available locally (will be pulled on first run)"
    fi

    # Test 6: Git status (security check)
    print_test "Git security check (.env not tracked)"
    if git ls-files | grep -q "\.env$"; then
        print_fail ".env file is tracked in git (SECURITY RISK)"
    else
        print_pass ".env file not tracked in git"
    fi
}

# =========================================
# INTEGRATION TESTS - System Level
# =========================================
