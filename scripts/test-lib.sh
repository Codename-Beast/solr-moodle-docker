#!/bin/bash
# Copyright (c) 2026 eLeDia GmbH / Bernd Schreistetter (bsc)
# SPDX-License-Identifier: MIT
# Version: v3.1.0
#
# eLeDia Test Library — colors, counters, print helpers
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
# Test Library — sourced by run-tests.sh and test modules

_is_cloud_mode() { [ "${SOLR_MODE}" = "solrcloud" ]; }


wait_for_solr_ready() {
    local admin_pass="$1"
    local waited=0
    while [ "$waited" -lt 180 ]; do
        if curl -s -o /dev/null -w '%{http_code}' -u "admin:${admin_pass}" \
            "http://${SOLR_HOST}:${SOLR_PORT}/solr/admin/info/system" 2>/dev/null | grep -q '^200$'; then
            return 0
        fi
        sleep 3
        waited=$((waited + 3))
    done
    return 1
}

# Helper functions

print_header() {
    echo -e "\n${BOLD}${BLUE}========================================${NC}"
    echo -e "${BOLD}${BLUE}$1${NC}"
    echo -e "${BOLD}${BLUE}========================================${NC}\n"
}


print_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
    ((TESTS_TOTAL++))
}


print_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((TESTS_PASSED++))
}


print_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((TESTS_FAILED++))
    FAILED_TESTS+=("$1")
}


print_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $1"
    ((TESTS_SKIPPED++))
}


print_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

# Check if running from correct directory
if [ ! -f "docker-compose.yml" ]; then
    echo -e "${RED}ERROR: Must be run from project root directory${NC}"
    exit 1
fi

# Check .env exists
if [ ! -f ".env" ]; then
    echo -e "${RED}ERROR: .env not found. Run setup first: ./setup.sh${NC}"
    exit 1
fi

# =========================================
# UNIT TESTS - Component Level
# =========================================

