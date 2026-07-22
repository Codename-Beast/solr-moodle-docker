#!/bin/bash
# Copyright (c) 2026 eLeDia.de / Bernd Schreistetter (bsc)
# Version: v3.4.12
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
RUN_TENANT_COMMANDS=0
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
        --no-performance) RUN_PERFORMANCE=0; shift ;;
        --tenant)         RUN_TENANT=1; RUN_TENANT_COMMANDS=1; shift ;;
        --tenant-commands) RUN_TENANT_COMMANDS=1; shift ;;
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
            echo "  --no-performance     Skip timing/load performance tests"
            echo "  --tenant             Run multi-tenant isolation tests and command matrix"
            echo "  --tenant-commands    Run solr-tenant.sh command matrix against running stack"
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
if [ $RUN_TENANT -eq 1 ] || [ $RUN_TENANT_COMMANDS -eq 1 ] || [ $RUN_CLOUD -eq 1 ] || [ $RUN_MODE_SWITCH -eq 1 ]; then
    RUN_INTEGRATION=1
fi

echo -e "${BOLD}${BLUE}"
cat << "EOF"
╔═══════════════════════════════════════╗
║   Solr for Moodle - Test Suite        ║
║   eLeDia.de Testing Framework         ║
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
if [ $RUN_TENANT_COMMANDS -eq 1 ]; then
    tenant_command_container="${SOLR_TEST_CONTAINER:-}"
    if [ -z "$tenant_command_container" ]; then
        tenant_command_instance="${INSTANCE_NAME:-}"
        if [ -z "$tenant_command_instance" ] && [ -f .env ]; then
            tenant_command_instance="$(grep -E '^INSTANCE_NAME=' .env | tail -n1 | cut -d= -f2-)"
        fi
        tenant_command_container="${tenant_command_instance:-solr}-solr"
    fi
    if SOLR_TEST_CONTAINER="$tenant_command_container" SOLR_TEST_PREFIX="cmdtest$$" "${SCRIPT_DIR}/test-tenant-commands.sh"; then
        print_pass "solr-tenant.sh command matrix"
    else
        print_fail "solr-tenant.sh command matrix"
    fi
fi
[ $RUN_TENANT_SCALE -eq 1 ] && { source "${SCRIPT_DIR}/test-integration.sh"; tenant_scale_tests; }
[ $RUN_CLOUD -eq 1 ] && { source "${SCRIPT_DIR}/test-moodle.sh"; solrcloud_tests; }
[ $RUN_MODE_SWITCH -eq 1 ] && { source "${SCRIPT_DIR}/test-moodle.sh"; mode_switch_tests; }
[ $RUN_CLEANUP -eq 1 ] && { source "${SCRIPT_DIR}/test-moodle.sh"; cleanup_tests; }

# Backfill the failed-test list from the run log if a sourced test emitted a
# raw [FAIL] line without using the shared print_fail implementation. This keeps
# the summary honest and prevents hidden failures in CI output.
if [ "$TESTS_FAILED" -gt "${#FAILED_TESTS[@]}" ] && [ -f "$RUN_LOG_FILE" ]; then
    while IFS= read -r fail_line; do
        fail_msg="$(printf '%s\n' "$fail_line" | sed -E 's/.*\[FAIL\][[:space:]]*//')"
        [ -n "$fail_msg" ] || continue
        duplicate=0
        for existing in "${FAILED_TESTS[@]}"; do
            [ "$existing" = "$fail_msg" ] && duplicate=1 && break
        done
        [ "$duplicate" -eq 0 ] && FAILED_TESTS+=("$fail_msg")
    done < <(grep -E '\[FAIL\]' "$RUN_LOG_FILE" || true)
fi

# Print summary
print_header "TEST SUMMARY"
echo -e "${BOLD}Total Tests:${NC}   $TESTS_TOTAL"
echo -e "${GREEN}${BOLD}Passed:${NC}        $TESTS_PASSED"
echo -e "${RED}${BOLD}Failed:${NC}        $TESTS_FAILED"
echo -e "${YELLOW}${BOLD}Skipped:${NC}       $TESTS_SKIPPED"
echo ""
echo -e "${BOLD}Run Log:${NC}       ${RUN_LOG_FILE}"
docker compose logs --no-color >> "${RUN_LOG_FILE}" 2>&1 || true

if [ "$TESTS_FAILED" -gt 0 ]; then
    echo -e "${RED}${BOLD}Failed Tests:${NC}"
    for test in "${FAILED_TESTS[@]}"; do
        echo -e "  ${RED}x${NC} $test"
    done
    echo ""
fi

if [ "$TESTS_TOTAL" -gt 0 ]; then
    success_rate=$((TESTS_PASSED * 100 / TESTS_TOTAL))
    echo -e "${BOLD}Success Rate:${NC}  ${success_rate}%"
    if [ "$TESTS_FAILED" -gt 0 ]; then
        echo -e "\n${RED}${BOLD}TEST SUITE FAILED${NC}"
        exit 1
    fi
    echo -e "\n${GREEN}${BOLD}TEST SUITE PASSED${NC}"
    exit 0
else
    echo -e "\n${YELLOW}${BOLD}NO TESTS RUN${NC}"
    exit 1
fi
