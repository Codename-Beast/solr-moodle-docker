#!/bin/bash
# Copyright (c) 2026 Eledia GmbH / Bernd Schreistetter
# SPDX-License-Identifier: MIT
# Version: v3.1.0
#
# run-tests.sh — Main test orchestrator
# Sources modular test suites and dispatches by CLI flags.
#
# Usage: ./scripts/run-tests.sh [OPTIONS]
# Run with --help for full option list.

set -o pipefail

# Source test library (colors, counters, helpers)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-lib.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

# Test counters
TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
declare -a FAILED_TESTS

# Get dynamic container names from .env or fallback
if [ -f ".env" ]; then
    source .env
fi
INSTANCE_NAME="${INSTANCE_NAME:-solr}"
SOLR_CONTAINER="${INSTANCE_NAME}-solr"
INIT_CONTAINER="${INSTANCE_NAME}-init"
SOLR_HOST="127.0.0.1"
SOLR_PORT="${SOLR_PORT:-8983}"
SOLR_CORE_NAME="${SOLR_CORE_NAME:-eLeDia_core}"
SOLR_MODE="${SOLR_MODE:-}"

if ! echo "${SOLR_HEAP:-2g}" | grep -Eq '^[0-9]+[mMgG]$'; then
    echo "ERROR: SOLR_HEAP='${SOLR_HEAP:-}' ist ungueltig. Erwartet z.B. 2g oder 1024m." >&2
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
    echo "WARN: using fallback LOG_ROOT=${LOG_ROOT}" >&2
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

# Parse arguments
RUN_UNIT=1
RUN_INTEGRATION=1
RUN_SECURITY=1
RUN_NEGATIVE=1
RUN_PERFORMANCE=1
RUN_MOODLE=1
RUN_CLEANUP=1
RUN_TENANT=0
RUN_TENANT_SCALE=0
RUN_CLOUD=0
RUN_MODE_SWITCH=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --unit-only)
            RUN_INTEGRATION=0; RUN_SECURITY=0; RUN_NEGATIVE=0
            RUN_PERFORMANCE=0; RUN_MOODLE=0; RUN_CLEANUP=0
            shift ;;
        --integration-only)
            RUN_UNIT=0; RUN_SECURITY=0; RUN_PERFORMANCE=0
            RUN_MOODLE=0; RUN_CLEANUP=0
            shift ;;
        --security-only)
            RUN_UNIT=0; RUN_INTEGRATION=0; RUN_NEGATIVE=0
            RUN_PERFORMANCE=0; RUN_MOODLE=0; RUN_CLEANUP=0
            shift ;;
        --negative-only)
            RUN_UNIT=0; RUN_INTEGRATION=0; RUN_SECURITY=0
            RUN_PERFORMANCE=0; RUN_MOODLE=0; RUN_CLEANUP=0
            shift ;;
        --moodle-only)
            RUN_UNIT=0; RUN_INTEGRATION=0; RUN_SECURITY=0
            RUN_NEGATIVE=0; RUN_PERFORMANCE=0; RUN_CLEANUP=0
            shift ;;
        --no-cleanup)     RUN_CLEANUP=0; shift ;;
        --tenant)         RUN_TENANT=1; shift ;;
        --tenant-scale)   RUN_TENANT=1; RUN_TENANT_SCALE=1; shift ;;
        --cloud|--solrcloud) RUN_CLOUD=1; SOLR_MODE=solrcloud; shift ;;
        --mode-switch)    RUN_MODE_SWITCH=1; shift ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --unit-only          Run only unit tests"
            echo "  --integration-only   Run only integration tests"
            echo "  --security-only      Run only security tests"
            echo "  --negative-only      Run only negative tests"
            echo "  --moodle-only        Run only Moodle document tests"
            echo "  --no-cleanup         Skip cleanup tests"
            echo "  --tenant             Run multi-tenant isolation tests"
            echo "  --tenant-scale       Run tenant scale test (30 tenants/cores/users)"
            echo "  --cloud              Run SolrCloud-specific tests"
            echo "  --mode-switch        Validate standalone <-> solrcloud switch continuity"
            echo "  --help               Show this help"
            echo ""
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Tenant/Cloud suites require running stack
if [ $RUN_TENANT -eq 1 ] || [ $RUN_CLOUD -eq 1 ] || [ $RUN_MODE_SWITCH -eq 1 ]; then
    RUN_INTEGRATION=1
fi

echo -e "${BOLD}${BLUE}"
cat << "EOF"
╔═══════════════════════════════════════╗
║   Solr for Moodle - Test Suite        ║
║   Eledia Testing Framework            ║
╚═══════════════════════════════════════╝
EOF
echo -e "${NC}"

# Source and run test suites
[ $RUN_UNIT -eq 1 ] && { source "${SCRIPT_DIR}/test-unit.sh"; unit_tests; }
[ $RUN_INTEGRATION -eq 1 ] && { source "${SCRIPT_DIR}/test-integration.sh"; integration_tests; }
[ $RUN_SECURITY -eq 1 ] && { source "${SCRIPT_DIR}/test-security.sh"; security_tests; }
[ $RUN_NEGATIVE -eq 1 ] && { source "${SCRIPT_DIR}/test-security.sh"; negative_tests; }
[ $RUN_PERFORMANCE -eq 1 ] && { source "${SCRIPT_DIR}/test-security.sh"; performance_tests; }
[ $RUN_MOODLE -eq 1 ] && { source "${SCRIPT_DIR}/test-moodle.sh"; moodle_document_tests; }
[ $RUN_TENANT -eq 1 ] && { source "${SCRIPT_DIR}/test-integration.sh"; tenant_tests; }
[ $RUN_TENANT_SCALE -eq 1 ] && { source "${SCRIPT_DIR}/test-integration.sh"; tenant_scale_tests; }
[ $RUN_CLOUD -eq 1 ] && { source "${SCRIPT_DIR}/test-moodle.sh"; solrcloud_tests; }
[ $RUN_MODE_SWITCH -eq 1 ] && { source "${SCRIPT_DIR}/test-moodle.sh"; mode_switch_tests; }
[ $RUN_CLEANUP -eq 1 ] && { source "${SCRIPT_DIR}/test-moodle.sh"; cleanup_tests; }

# Print summary
print_header "TEST SUMMARY"
echo -e "${BOLD}Total Tests:${NC}   $TESTS_TOTAL"
echo -e "${GREEN}${BOLD}Passed:${NC}        $TESTS_PASSED"
echo -e "${RED}${BOLD}Failed:${NC}        $TESTS_FAILED"
echo -e "${YELLOW}${BOLD}Skipped:${NC}       $TESTS_SKIPPED"
echo ""
echo -e "${BOLD}Run Log:${NC}       ${RUN_LOG_FILE}"
docker compose logs --no-color >> "${RUN_LOG_FILE}" 2>&1 || true

if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "${RED}${BOLD}Failed Tests:${NC}"
    for test in "${FAILED_TESTS[@]}"; do
        echo -e "  ${RED}x${NC} $test"
    done
    echo ""
fi

if [ $TESTS_TOTAL -gt 0 ]; then
    success_rate=$((TESTS_PASSED * 100 / TESTS_TOTAL))
    echo -e "${BOLD}Success Rate:${NC}  ${success_rate}%"
    if [ $TESTS_FAILED -gt 0 ]; then
        echo -e "\n${RED}${BOLD}TEST SUITE FAILED${NC}"
        exit 1
    fi
    echo -e "\n${GREEN}${BOLD}TEST SUITE PASSED${NC}"
    exit 0
else
    echo -e "\n${YELLOW}${BOLD}NO TESTS RUN${NC}"
    exit 1
fi
