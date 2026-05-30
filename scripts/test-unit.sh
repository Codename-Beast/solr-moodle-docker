#!/bin/bash
# Copyright (c) 2026 eLeDia GmbH / Bernd Schreistetter (bsc)
# SPDX-License-Identifier: MIT
# Version: v3.1.0
#
# eLeDia Unit Tests — file checks, compose config, Dockerfile
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
INIT_CONTAINER="${INSTANCE_NAME}-eLeDia-solr-init"
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

