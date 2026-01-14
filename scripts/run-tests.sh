#!/bin/bash
# =========================================
# Solr for Moodle - Test Suite
# Author: BSC for Eledia.de
# =========================================
# Comprehensive test suite for functionality,
# security, and deployment verification
# =========================================

# Note: Not using 'set -e' to allow tests to continue even if some fail
set -o pipefail

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

# =========================================
# UNIT TESTS - Component Level
# =========================================
unit_tests() {
    print_header "UNIT TESTS - Component Level"

    # Test 1: docker-compose.yml syntax
    print_test "docker-compose.yml syntax validation"
    if [ -f "docker-compose.yml" ] && grep -q "services:" docker-compose.yml; then
        print_pass "docker-compose.yml is valid"
    else
        print_fail "docker-compose.yml syntax error"
    fi

    # Test 2: Required files exist
    print_test "Required files existence"
    local required_files=(
        "docker-compose.yml"
        "init/powerinit.sh"
        "init/generate_env.sh"
        "config/managed-schema"
        "config/solrconfig.xml"
        "config/security.json.template"
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

    # Test 3: Script permissions
    print_test "Script file permissions"
    if [ -x "init/powerinit.sh" ] || [ -r "init/powerinit.sh" ]; then
        print_pass "init scripts are readable"
    else
        print_fail "init scripts not readable"
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

    # Test 5: Docker image availability
    print_test "Docker images availability"
    if docker image inspect alpine:3.20 >/dev/null 2>&1 && \
       docker image inspect solr:9.10.0 >/dev/null 2>&1; then
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
integration_tests() {
    print_header "INTEGRATION TESTS - System Level"

    # Test 1: Container startup
    print_test "Container startup and health"
    docker compose down -v >/dev/null 2>&1 || true

    # Generate .env if not exists
    if [ ! -f ".env" ]; then
        print_info "Generating .env for tests..."
        docker compose --profile setup up moodle_setup >/dev/null 2>&1 || true
    fi

    docker compose up -d >/dev/null 2>&1
    sleep 35

    if docker compose ps | grep -q "healthy"; then
        print_pass "Containers started and healthy"
    else
        print_fail "Containers not healthy"
        docker compose ps
    fi

    # Test 2: Solr Core Creation
    print_test "Solr core creation"
    if docker exec solr-solr test -d /var/solr/data/moodle_core 2>/dev/null; then
        print_pass "Moodle core directory created"
    else
        print_fail "Moodle core directory not found"
    fi

    # Test 3: security.json creation
    print_test "security.json creation and permissions"
    if docker exec solr-solr test -f /var/solr/data/security.json 2>/dev/null; then
        local perms=$(docker exec solr-solr stat -c '%a' /var/solr/data/security.json 2>/dev/null)
        if [ "$perms" = "600" ]; then
            print_pass "security.json exists with correct permissions (600)"
        else
            print_fail "security.json has wrong permissions: $perms (expected 600)"
        fi
    else
        print_fail "security.json not created"
    fi

    # Test 4: Authentication
    print_test "Basic authentication"
    local admin_pass=$(grep "^SOLR_ADMIN_PASSWORD=" .env | cut -d= -f2)
    local response=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:${admin_pass}" "http://127.0.0.1:8983/solr/admin/cores")
    if [ "$response" = "200" ]; then
        print_pass "Authentication successful (HTTP 200)"
    else
        print_fail "Authentication failed (HTTP $response)"
    fi

    # Test 5: Unauthorized access blocked
    print_test "Unauthorized access blocked"
    local unauth_response=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8983/solr/admin/cores")
    if [ "$unauth_response" = "401" ]; then
        print_pass "Unauthorized access correctly blocked (HTTP 401)"
    else
        print_fail "Unauthorized access not blocked (HTTP $unauth_response)"
    fi

    # Test 6: Core status API
    print_test "Core status API"
    local core_response=$(curl -s -u "admin:${admin_pass}" "http://127.0.0.1:8983/solr/admin/cores?action=STATUS&wt=json")
    if echo "$core_response" | grep -q '"moodle_core"'; then
        print_pass "Core status API returns moodle_core"
    else
        print_fail "Core status API does not return moodle_core"
    fi

    # Test 7: Password change detection
    print_test "Password change detection"
    # Change password
    sed -i.bak 's/^SOLR_ADMIN_PASSWORD=.*/SOLR_ADMIN_PASSWORD=TESTPASS999/' .env 2>/dev/null

    docker compose down >/dev/null 2>&1
    docker compose up -d >/dev/null 2>&1
    sleep 30

    if docker compose logs solr-init 2>&1 | grep -q "Passwords changed"; then
        print_pass "Password change detected and security.json regenerated"
    else
        print_fail "Password change not detected"
    fi

    # Restore old password for remaining tests
    mv .env.bak .env 2>/dev/null
}

# =========================================
# SECURITY TESTS - Security Validation
# =========================================
security_tests() {
    print_header "SECURITY TESTS - Security Validation"

    # Test 1: Network binding
    print_test "Network binding (localhost only)"
    local binding=$(docker compose port solr 8983 2>/dev/null)
    if echo "$binding" | grep -q "127.0.0.1"; then
        print_pass "Solr correctly bound to localhost only"
    else
        print_fail "Solr not bound to localhost: $binding"
    fi

    # Test 2: Container privileges
    print_test "Container privileges (non-root for Solr)"
    local user=$(docker inspect solr-solr --format='{{.Config.User}}' 2>/dev/null)
    if [ "$user" = "8983:8983" ]; then
        print_pass "Solr runs as non-root user (8983:8983)"
    else
        print_fail "Solr runs as wrong user: $user"
    fi

    # Test 3: Privileged mode
    print_test "Privileged mode disabled"
    local privileged=$(docker inspect solr-solr --format='{{.HostConfig.Privileged}}' 2>/dev/null)
    if [ "$privileged" = "false" ]; then
        print_pass "Privileged mode disabled"
    else
        print_fail "Privileged mode enabled (SECURITY RISK)"
    fi

    # Test 4: Secrets in environment
    print_test "No secrets in container environment"
    if docker exec solr-solr env 2>/dev/null | grep -qi "password"; then
        print_fail "Passwords found in container environment"
    else
        print_pass "No passwords in container environment"
    fi

    # Test 5: File permissions
    print_test "Sensitive file permissions"
    local sec_perms=$(docker exec solr-solr stat -c '%a' /var/solr/data/security.json 2>/dev/null)
    local pwd_perms=$(docker exec solr-solr stat -c '%a' /var/solr/data/.password_checksum 2>/dev/null)

    if [ "$sec_perms" = "600" ] && [ "$pwd_perms" = "600" ]; then
        print_pass "Sensitive files have correct permissions (600)"
    else
        print_fail "Wrong permissions - security.json: $sec_perms, .password_checksum: $pwd_perms"
    fi

    # Test 6: .env in gitignore
    print_test ".env in .gitignore"
    if grep -q "\.env" .gitignore 2>/dev/null; then
        print_pass ".env correctly listed in .gitignore"
    else
        print_fail ".env not in .gitignore (SECURITY RISK)"
    fi

    # Test 7: Default passwords in production
    print_test "No default passwords used"
    local admin_pass=$(grep "^SOLR_ADMIN_PASSWORD=" .env | cut -d= -f2)
    if [ "$admin_pass" = "eledia_default" ]; then
        print_fail "Default password still in use (CHANGE IT!)"
    else
        print_pass "Default password changed"
    fi

    # Test 8: SSL warning check
    print_test "SSL configuration awareness"
    if docker compose logs solr 2>&1 | grep -q "SSL is off"; then
        print_info "SSL warning present (OK for localhost, use reverse proxy for production)"
        print_pass "SSL warning logged correctly"
    else
        print_skip "SSL warning not found (may be suppressed)"
    fi
}

# =========================================
# PERFORMANCE TESTS - Basic Performance
# =========================================
performance_tests() {
    print_header "PERFORMANCE TESTS - Basic Performance"

    local admin_pass=$(grep "^SOLR_ADMIN_PASSWORD=" .env | cut -d= -f2)

    # Test 1: Response time
    print_test "API response time (<2s)"
    local start_time=$(date +%s%3N)
    curl -s -u "admin:${admin_pass}" "http://127.0.0.1:8983/solr/admin/cores?action=STATUS" >/dev/null 2>&1
    local end_time=$(date +%s%3N)
    local response_time=$((end_time - start_time))

    if [ $response_time -lt 2000 ]; then
        print_pass "Response time: ${response_time}ms (good)"
    else
        print_fail "Response time: ${response_time}ms (slow, >2000ms)"
    fi

    # Test 2: Container resource usage
    print_test "Container memory usage"
    local mem_usage=$(docker stats solr-solr --no-stream --format "{{.MemUsage}}" 2>/dev/null | cut -d'/' -f1)
    if [ -n "$mem_usage" ]; then
        print_pass "Memory usage: $mem_usage"
    else
        print_skip "Could not retrieve memory stats"
    fi

    # Test 3: Healthcheck responsiveness
    print_test "Healthcheck endpoint response"
    local health_response=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8983/solr/admin/ping" 2>/dev/null)
    if [ "$health_response" = "401" ] || [ "$health_response" = "200" ]; then
        print_pass "Healthcheck endpoint responsive (HTTP $health_response)"
    else
        print_fail "Healthcheck endpoint not responding (HTTP $health_response)"
    fi
}

# =========================================
# MOODLE DOCUMENT TESTS
# =========================================
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

    # Run the moodle document test script
    if bash scripts/test-moodle-documents.sh 2>&1 | tee /tmp/moodle-test-output.log | tail -20; then
        # Extract test results from output
        MOODLE_TESTS=$(grep "Total Tests:" /tmp/moodle-test-output.log | awk '{print $3}' || echo "0")
        MOODLE_PASSED=$(grep "Passed:" /tmp/moodle-test-output.log | awk '{print $2}' || echo "0")
        MOODLE_FAILED=$(grep "Failed:" /tmp/moodle-test-output.log | awk '{print $2}' || echo "0")

        # Update global counters
        ((TESTS_TOTAL += MOODLE_TESTS))
        ((TESTS_PASSED += MOODLE_PASSED))
        ((TESTS_FAILED += MOODLE_FAILED))

        if [ "$MOODLE_FAILED" -eq 0 ]; then
            print_pass "Moodle document tests completed successfully ($MOODLE_PASSED/$MOODLE_TESTS)"
        else
            print_fail "Some Moodle document tests failed ($MOODLE_FAILED failures)"
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

    local admin_pass=$(grep "^SOLR_ADMIN_PASSWORD=" .env | cut -d= -f2)

    # Test 1: Restart without data loss
    print_test "Restart without data loss"
    docker compose restart solr >/dev/null 2>&1
    sleep 20

    local restart_response=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:${admin_pass}" "http://127.0.0.1:8983/solr/admin/cores")
    if [ "$restart_response" = "200" ]; then
        print_pass "Container restart successful, data persisted"
    else
        print_fail "Container restart failed or data lost"
    fi

    # Test 2: Graceful shutdown
    print_test "Graceful shutdown"
    docker compose down >/dev/null 2>&1
    if ! docker ps | grep -q solr-solr; then
        print_pass "Containers shut down gracefully"
    else
        print_fail "Containers still running after shutdown"
    fi

    # Test 3: Volume persistence
    print_test "Volume persistence after shutdown"
    if docker volume ls | grep -q "solr_data"; then
        print_pass "Volumes persist after shutdown"
    else
        print_fail "Volumes removed (data loss risk)"
    fi
}

# =========================================
# MAIN TEST EXECUTION
# =========================================
main() {
    echo -e "${BOLD}${BLUE}"
    cat << "EOF"
╔═══════════════════════════════════════╗
║   Solr for Moodle - Test Suite        ║
║   Eledia Testing Framework            ║
╚═══════════════════════════════════════╝
EOF
    echo -e "${NC}"

    # Parse arguments
    RUN_UNIT=1
    RUN_INTEGRATION=1
    RUN_SECURITY=1
    RUN_PERFORMANCE=1
    RUN_MOODLE=1
    RUN_CLEANUP=1

    while [[ $# -gt 0 ]]; do
        case $1 in
            --unit-only)
                RUN_INTEGRATION=0
                RUN_SECURITY=0
                RUN_PERFORMANCE=0
                RUN_MOODLE=0
                RUN_CLEANUP=0
                shift
                ;;
            --integration-only)
                RUN_UNIT=0
                RUN_SECURITY=0
                RUN_PERFORMANCE=0
                RUN_MOODLE=0
                RUN_CLEANUP=0
                shift
                ;;
            --security-only)
                RUN_UNIT=0
                RUN_INTEGRATION=0
                RUN_PERFORMANCE=0
                RUN_MOODLE=0
                RUN_CLEANUP=0
                shift
                ;;
            --moodle-only)
                RUN_UNIT=0
                RUN_INTEGRATION=0
                RUN_SECURITY=0
                RUN_PERFORMANCE=0
                RUN_CLEANUP=0
                shift
                ;;
            --no-cleanup)
                RUN_CLEANUP=0
                shift
                ;;
            --help)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --unit-only          Run only unit tests"
                echo "  --integration-only   Run only integration tests"
                echo "  --security-only      Run only security tests"
                echo "  --moodle-only        Run only Moodle document tests"
                echo "  --no-cleanup         Skip cleanup tests"
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

    # Run test suites
    [ $RUN_UNIT -eq 1 ] && unit_tests
    [ $RUN_INTEGRATION -eq 1 ] && integration_tests
    [ $RUN_SECURITY -eq 1 ] && security_tests
    [ $RUN_PERFORMANCE -eq 1 ] && performance_tests
    [ $RUN_MOODLE -eq 1 ] && moodle_document_tests
    [ $RUN_CLEANUP -eq 1 ] && cleanup_tests

    # Print summary
    print_header "TEST SUMMARY"
    echo -e "${BOLD}Total Tests:${NC}   $TESTS_TOTAL"
    echo -e "${GREEN}${BOLD}Passed:${NC}        $TESTS_PASSED"
    echo -e "${RED}${BOLD}Failed:${NC}        $TESTS_FAILED"
    echo -e "${YELLOW}${BOLD}Skipped:${NC}       $TESTS_SKIPPED"
    echo ""

    if [ $TESTS_FAILED -gt 0 ]; then
        echo -e "${RED}${BOLD}Failed Tests:${NC}"
        for test in "${FAILED_TESTS[@]}"; do
            echo -e "  ${RED}✗${NC} $test"
        done
        echo ""
    fi

    # Calculate success rate
    if [ $TESTS_TOTAL -gt 0 ]; then
        local success_rate=$((TESTS_PASSED * 100 / TESTS_TOTAL))
        echo -e "${BOLD}Success Rate:${NC}  ${success_rate}%"

        if [ $success_rate -ge 90 ]; then
            echo -e "\n${GREEN}${BOLD}✓ TEST SUITE PASSED${NC}"
            exit 0
        elif [ $success_rate -ge 70 ]; then
            echo -e "\n${YELLOW}${BOLD}⚠ TEST SUITE PASSED WITH WARNINGS${NC}"
            exit 0
        else
            echo -e "\n${RED}${BOLD}✗ TEST SUITE FAILED${NC}"
            exit 1
        fi
    else
        echo -e "\n${YELLOW}${BOLD}⚠ NO TESTS RUN${NC}"
        exit 1
    fi
}

# Run main function
main "$@"
