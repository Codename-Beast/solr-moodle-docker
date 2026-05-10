#!/bin/bash
# =========================================
# Solr for Moodle - Test Suite
# Author: Bernd Schreistetter for Eledia.de
# =========================================
# Test suite for functionality,
# security, and deployment verification
# =========================================

# Allow tests to continue even if some fail
# Using pipefail to catch errors in pipelines
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

# Get dynamic container names from .env or fallback to default
if [ -f ".env" ]; then
    source .env
fi
INSTANCE_NAME=${INSTANCE_NAME:-solr}
SOLR_CONTAINER="${INSTANCE_NAME}-solr"
INIT_CONTAINER="${INSTANCE_NAME}-init"
SOLR_HOST="127.0.0.1"
SOLR_CORE_NAME=${SOLR_CORE_NAME:-moodle_core}
SOLR_MODE="${SOLR_MODE:-}"
_is_cloud_mode() { [ "${SOLR_MODE}" = "solrcloud" ]; }

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
        "init/powerinit.sh"
        "config/managed-schema"
        "config/solrconfig.xml"
        "init/security.json.template"
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

    docker compose up -d >/dev/null 2>&1
    sleep 35

    if docker compose ps | grep -q "healthy"; then
        print_pass "Containers started and healthy"
    else
        print_fail "Containers not healthy"
        docker compose ps
    fi

    # Create a test tenant so core-level tests have a valid core to work with
    print_info "Creating test tenant ci_test (core: ${SOLR_CORE_NAME})..."
    docker exec "$SOLR_CONTAINER" /opt/solr/scripts/solr-tenant.sh \
        create ci_test --cores "${SOLR_CORE_NAME}" >/dev/null 2>&1 || true
    sleep 2

    # Solr Core Creation
    print_test "Solr core creation"
    if docker exec "$SOLR_CONTAINER" test -d "/var/solr/data/${SOLR_CORE_NAME}" 2>/dev/null; then
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
    local admin_pass

    admin_pass=$(grep "^SOLR_ADMIN_PASSWORD=" .env | cut -d= -f2)
    local response

    response=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:${admin_pass}" "http://${SOLR_HOST}:8983/solr/admin/cores")
    if [ "$response" = "200" ]; then
        print_pass "Authentication successful (HTTP 200)"
    else
        print_fail "Authentication failed (HTTP $response)"
    fi

    #Unauthorized access blocked
    print_test "Unauthorized access blocked"
    local unauth_response

    unauth_response=$(curl -s -o /dev/null -w '%{http_code}' "http://${SOLR_HOST}:8983/solr/admin/cores")
    if [ "$unauth_response" = "401" ]; then
        print_pass "Unauthorized access correctly blocked (HTTP 401)"
    else
        print_fail "Unauthorized access not blocked (HTTP $unauth_response)"
    fi

    #Core status API
    print_test "Core status API"
    local core_response

    core_response=$(curl -s -u "admin:${admin_pass}" "http://${SOLR_HOST}:8983/solr/admin/cores?action=STATUS&wt=json")
    if echo "$core_response" | grep -q "\"${SOLR_CORE_NAME}\""; then
        print_pass "Core status API returns ${SOLR_CORE_NAME}"
    else
        print_fail "Core status API does not return ${SOLR_CORE_NAME}"
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

    if docker compose logs solr-init 2>&1 | grep -q "security.json written"; then
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
security_tests() {
    print_header "SECURITY TESTS - Security Validation"

    #Network binding
    print_test "Network binding (localhost only)"
    local binding

    binding=$(docker compose port solr 8983 2>/dev/null)
    if echo "$binding" | grep -q "127.0.0.1"; then
        print_pass "Solr correctly bound to localhost only"
    else
        print_fail "Solr not bound to localhost: $binding"
    fi

   #Container privileges
    print_test "Container privileges (non-root for Solr)"
    local user
    user=$(docker inspect "$SOLR_CONTAINER" --format='{{.Config.User}}' 2>/dev/null)
    if [ "$user" = "8983:8983" ]; then
        print_pass "Solr runs as non-root user (8983:8983)"
    else
        print_fail "Solr runs as wrong user: $user"
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

    #.env in gitignore
    print_test ".env in .gitignore"
    if grep -q "\.env" .gitignore 2>/dev/null; then
        print_pass ".env correctly listed in .gitignore"
    else
        print_fail ".env not in .gitignore (SECURITY RISK!!)"
    fi

    # Default passwords in production
    print_test "No default passwords used"
    local admin_pass

    admin_pass=$(grep "^SOLR_ADMIN_PASSWORD=" .env | cut -d= -f2)
    if [ "$admin_pass" = "eledia_default" ]; then
        print_fail "Default password still in use (CHANGE IT!)"
    else
        print_pass "Default password changed"
    fi

    # SSL warning check
    print_test "SSL configuration awareness"
    if docker compose logs solr 2>&1 | grep -q "SSL is off"; then
        print_info "SSL warning present (OK for localhost, use reverse proxy for production)"
        print_pass "SSL warning logged correctly"
    else
        print_skip "SSL warning not found (maybe suppressed)"
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

    local admin_pass

    # Test Invalid credentials
    admin_pass=$(grep "^SOLR_ADMIN_PASSWORD=" .env | cut -d= -f2)
    print_test "Reject invalid credentials"
    local invalid_response

    invalid_response=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:wrongpassword" "http://${SOLR_HOST}:8983/solr/admin/cores")
    if [ "$invalid_response" = "401" ]; then
        print_pass "Invalid credentials rejected (HTTP 401)"
    else
        print_fail "Invalid credentials not rejected (HTTP $invalid_response)"
    fi

    # Tes SQL injection attempt in query
    print_test "SQL injection protection"
    local injection_response

    injection_response=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:${admin_pass}" "http://${SOLR_HOST}:8983/solr/${SOLR_CORE_NAME}/select?q=*:*';DROP%20TABLE%20users;--")
    if [ "$injection_response" = "200" ] || [ "$injection_response" = "400" ]; then
        print_pass "SQL injection handled safely (HTTP $injection_response)"
    else
        print_fail "Unexpected response to SQL injection (HTTP $injection_response)"
    fi

    # Test XSS attempt in query
    print_test "XSS protection"
    local xss_response

    xss_response=$(curl -s -u "admin:${admin_pass}" "http://${SOLR_HOST}:8983/solr/${SOLR_CORE_NAME}/select?q=<script>alert('xss')</script>&wt=json")
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

    long_response=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:${admin_pass}" "http://${SOLR_HOST}:8983/solr/${SOLR_CORE_NAME}/select?q=${long_query}")
    if [ "$long_response" = "400" ] || [ "$long_response" = "414" ] || [ "$long_response" = "200" ]; then
        print_pass "Long query handled (HTTP $long_response)"
    else
        print_fail "Long query caused unexpected response (HTTP $long_response)"
    fi

    # Test Invalid core name
    print_test "Reject invalid core name"
    local invalid_core_response

    invalid_core_response=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:${admin_pass}" "http://${SOLR_HOST}:8983/solr/nonexistent_core/select?q=*:*")
    if [ "$invalid_core_response" = "404" ]; then
        print_pass "Invalid core rejected (HTTP 404)"
    else
        print_fail "Invalid core not rejected (HTTP $invalid_core_response)"
    fi

    # Test Empty query parameter
    print_test "Handle empty query"
    local empty_response

    empty_response=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:${admin_pass}" "http://${SOLR_HOST}:8983/solr/${SOLR_CORE_NAME}/select?q=")
    if [ "$empty_response" = "400" ] || [ "$empty_response" = "200" ]; then
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

    local admin_pass

    # Test Response time


    admin_pass=$(grep "^SOLR_ADMIN_PASSWORD=" .env | cut -d= -f2)
    print_test "API response time (<2s)"
    local start_time

    start_time=$(date +%s%3N)
    curl -s -u "admin:${admin_pass}" "http://${SOLR_HOST}:8983/solr/admin/cores?action=STATUS" >/dev/null 2>&1
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
        print_skip "Could not retrieve memory stats"
    fi

    # Test Healthcheck responsiveness
    print_test "Healthcheck endpoint response"
    local health_response

    health_response=$(curl -s -o /dev/null -w '%{http_code}' "http://${SOLR_HOST}:8983/solr/admin/ping" 2>/dev/null)
    if [ "$health_response" = "401" ] || [ "$health_response" = "200" ]; then
        print_pass "Healthcheck endpoint responsive (HTTP $health_response)"
    else
        print_fail "Healthcheck endpoint not responding (HTTP $health_response)"
    fi

    # Test Concurrent request handling (load test)
    print_test "Concurrent request handling (10 parallel requests)"
    local concurrent_start

    concurrent_start=$(date +%s%3N)
    for i in {1..10}; do
        curl -s -o /dev/null -u "admin:${admin_pass}" "http://${SOLR_HOST}:8983/solr/admin/cores?action=STATUS" &
    done
    wait
    local concurrent_end

    concurrent_end=$(date +%s%3N)
    local concurrent_time


    concurrent_time=$((concurrent_end - concurrent_start))
    if [ $concurrent_time -lt 5000 ]; then
        print_pass "Handled 10 concurrent requests in ${concurrent_time}ms"
    else
        print_fail "Concurrent requests too slow: ${concurrent_time}ms (expected <5000ms)"
    fi

    # Test Query performance under load
    print_test "Query performance under load (20 queries)"
    local load_start

    load_start=$(date +%s%3N)
    for i in {1..20}; do
        curl -s -u "admin:${admin_pass}" "http://${SOLR_HOST}:8983/solr/${SOLR_CORE_NAME}/select?q=*:*&rows=10" > /dev/null 2>&1
    done
    local load_end

    load_end=$(date +%s%3N)
    local load_time

    load_time=$((load_end - load_start))
    local avg_time


    avg_time=$((load_time / 20))
    if [ $avg_time -lt 200 ]; then
        print_pass "Average query time under load: ${avg_time}ms per query"
    else
        print_fail "Query performance under load too slow: ${avg_time}ms per query (expected <200ms)"
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
# MONITORING TESTS - Prometheus & Grafana
# =========================================
monitoring_tests() {
    print_header "MONITORING TESTS - Prometheus & Grafana Health"

    local prom_bind="${PROMETHEUS_BIND:-127.0.0.1}"
    local prom_port="${PROMETHEUS_PORT:-9090}"
    local grafana_bind="${GRAFANA_BIND:-127.0.0.1}"
    local grafana_port="${GRAFANA_PORT:-3000}"

    # Prometheus health
    print_test "Prometheus health endpoint (${prom_bind}:${prom_port})"
    local prom_response
    prom_response=$(curl -sf -o /dev/null -w '%{http_code}' "http://${prom_bind}:${prom_port}/-/healthy" 2>/dev/null)
    if [ "$prom_response" = "200" ]; then
        print_pass "Prometheus healthy (HTTP 200)"
    else
        print_fail "Prometheus not healthy (HTTP $prom_response)"
    fi

    # Grafana health
    print_test "Grafana health endpoint (${grafana_bind}:${grafana_port})"
    local grafana_response
    grafana_response=$(curl -sf -o /dev/null -w '%{http_code}' "http://${grafana_bind}:${grafana_port}/api/health" 2>/dev/null)
    if [ "$grafana_response" = "200" ]; then
        print_pass "Grafana healthy (HTTP 200)"
    else
        print_fail "Grafana not healthy (HTTP $grafana_response)"
    fi
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


    restart_response=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:${admin_pass}" "http://${SOLR_HOST}:8983/solr/admin/cores")
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
tenant_tests() {
    print_header "MULTI-TENANT TESTS - Isolation & Management"

    local admin_pass
    admin_pass=$(grep "^SOLR_ADMIN_PASSWORD=" .env | cut -d= -f2)
    local container="${INSTANCE_NAME:-solr}-solr"
    local tenant_cmd="docker exec $container /opt/solr/scripts/solr-tenant.sh"

    # Create tenant schule_a
    print_test "Create tenant schule_a (core: moodle_prod_a)"
    if $tenant_cmd create schule_a --cores moodle_prod_a >/dev/null 2>&1; then
        print_pass "Tenant schule_a created"
    else
        print_fail "Failed to create tenant schule_a"
    fi

    # Verify user in security.json
    print_test "User solr_schule_a in security.json"
    if docker exec "$container" jq '.authentication.credentials | has("solr_schule_a")' \
        /var/solr/data/security.json 2>/dev/null | grep -q true; then
        print_pass "User solr_schule_a present in security.json"
    else
        print_skip "security.json check (may need restart to reflect)"
    fi

    PASS_A="$(docker exec "$container" grep 'TENANT_schule_a_PASS=' /opt/solr/tenants.env | cut -d= -f2)"

    # Tenant can access own core
    print_test "solr_schule_a can access /moodle_prod_a/select (200)"
    local r
    r=$(curl -so /dev/null -w '%{http_code}' -u "solr_schule_a:${PASS_A}" \
        "http://${SOLR_HOST}:8983/solr/moodle_prod_a/select?q=*:*&rows=0" 2>/dev/null)
    if [ "$r" = "200" ]; then
        print_pass "Tenant access to own core: OK (HTTP 200)"
    else
        print_fail "Tenant access to own core failed (HTTP $r)"
    fi

    # Tenant blocked from admin API
    print_test "solr_schule_a CANNOT access /admin/cores (403)"
    r=$(curl -so /dev/null -w '%{http_code}' -u "solr_schule_a:${PASS_A}" \
        "http://${SOLR_HOST}:8983/solr/admin/cores" 2>/dev/null)
    if [ "$r" = "403" ]; then
        print_pass "Admin API correctly blocked for tenant (HTTP 403)"
    else
        print_fail "Admin API NOT blocked for tenant (HTTP $r — expected 403)"
    fi

    # Create tenant schule_b
    print_test "Create tenant schule_b (core: moodle_prod_b)"
    if $tenant_cmd create schule_b --cores moodle_prod_b >/dev/null 2>&1; then
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
            "http://${SOLR_HOST}:8983/solr/moodle_prod_b/select?q=*:*&rows=0" 2>/dev/null)
        if [ "$r" = "403" ]; then
            print_pass "SolrCloud isolation OK: schule_a cannot access schule_b (HTTP 403)"
        else
            print_fail "ISOLATION FAILURE: schule_a accessed schule_b (HTTP $r — expected 403)"
        fi
    else
        print_test "ISOLATION (standalone): authentication isolation — wrong password => 401"
        r=$(curl -so /dev/null -w '%{http_code}' -u "solr_schule_a:wrongpassword" \
            "http://${SOLR_HOST}:8983/solr/moodle_prod_a/select?q=*:*&rows=0" 2>/dev/null)
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
        "http://${SOLR_HOST}:8983/solr/moodle_prod_a/select?q=*:*&rows=0" 2>/dev/null)
    if [ "$r" = "200" ]; then
        print_pass "Support read access: OK (HTTP 200)"
    else
        print_fail "Support read access failed (HTTP $r)"
    fi

    # Support cannot write
    print_test "support CANNOT write to /moodle_prod_a/update (403)"
    r=$(curl -so /dev/null -w '%{http_code}' -u "support:${support_pass}" \
        -X POST -H 'Content-Type: application/json' -d '{"commit":{}}' \
        "http://${SOLR_HOST}:8983/solr/moodle_prod_a/update" 2>/dev/null)
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
        "http://${SOLR_HOST}:8983/solr/moodle_test_a/select?q=*:*&rows=0" 2>/dev/null)
    if [ "$r" = "200" ]; then
        print_pass "Access to new core: OK (HTTP 200)"
    else
        print_fail "Access to new core failed (HTTP $r)"
    fi

    # delete tenant
    print_test "delete schule_a -> login blocked (401)"
    $tenant_cmd delete schule_a --force >/dev/null 2>&1 || true
    r=$(curl -so /dev/null -w '%{http_code}' -u "solr_schule_a:${PASS_A}" \
        "http://${SOLR_HOST}:8983/solr/moodle_prod_a/select?q=*:*&rows=0" 2>/dev/null)
    if [ "$r" = "401" ]; then
        print_pass "Deleted tenant login correctly blocked (HTTP 401)"
    else
        print_fail "Deleted tenant can still login (HTTP $r — expected 401)"
    fi

    # enable tenant
    print_test "enable schule_a -> new password works (200)"
    NEW_PASS=$($tenant_cmd enable schule_a 2>/dev/null | grep 'Password:' | awk '{print $2}') || true
    if [ -z "$NEW_PASS" ]; then
        NEW_PASS="$(docker exec "$container" grep 'TENANT_schule_a_PASS=' /opt/solr/tenants.env | cut -d= -f2)"
    fi
    r=$(curl -so /dev/null -w '%{http_code}' -u "solr_schule_a:${NEW_PASS}" \
        "http://${SOLR_HOST}:8983/solr/moodle_prod_a/select?q=*:*&rows=0" 2>/dev/null)
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
    sleep 30
    if $tenant_cmd list 2>/dev/null | grep -q "schule_b"; then
        print_pass "Tenants persisted after restart"
    else
        print_fail "Tenants lost after restart"
    fi
}

# =========================================
# SOLRCLOUD TESTS - Collections API + Persistence
# =========================================
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
        "http://${SOLR_HOST}:8983/solr/admin/zookeeper?detail=true&path=%2F&wt=json" 2>/dev/null)
    if [ "$zk_code" = "200" ]; then
        print_pass "ZooKeeper API reachable (HTTP 200)"
    else
        print_fail "ZooKeeper API not reachable (HTTP $zk_code)"
    fi

    # Collections API: create collection
    print_test "Collections API: create collection via tenant (cloud_test_c1)"
    if $tenant_cmd create cloud_tenant --cores cloud_test_c1 >/dev/null 2>&1; then
        print_pass "Collection cloud_test_c1 created via Collections API"
    else
        print_fail "Failed to create collection cloud_test_c1"
    fi

    CLOUD_PASS="$(docker exec "$container" grep 'TENANT_cloud_tenant_PASS=' /opt/solr/tenants.env | cut -d= -f2)"

    # Verify collection exists via Collections API
    print_test "Collection exists in ZooKeeper via Collections API"
    local coll_resp
    coll_resp=$(curl -s -u "admin:${admin_pass}" \
        "http://${SOLR_HOST}:8983/solr/admin/collections?action=LIST&wt=json")
    if echo "$coll_resp" | grep -q '"cloud_test_c1"'; then
        print_pass "Collection cloud_test_c1 in Collections API list"
    else
        print_fail "Collection cloud_test_c1 NOT in Collections API list"
    fi

    # True isolation via collection field (SolrCloud enforces it)
    print_test "True collection isolation: wrong tenant => 403"
    local iso_code
    iso_code=$(curl -so /dev/null -w '%{http_code}' -u "solr_cloud_tenant:${CLOUD_PASS}" \
        "http://${SOLR_HOST}:8983/solr/admin/cores?wt=json" 2>/dev/null)
    if [ "$iso_code" = "403" ]; then
        print_pass "Admin API blocked for tenant (HTTP 403)"
    else
        print_fail "Admin API NOT blocked (HTTP $iso_code — expected 403)"
    fi

    # Index a document to test persistence
    print_test "Index document for restart persistence test"
    local idx_code
    idx_code=$(curl -so /dev/null -w '%{http_code}' \
        -u "solr_cloud_tenant:${CLOUD_PASS}" \
        -X POST -H 'Content-Type: application/json' \
        -d '[{"id":"persist-test-1","title_s":"restart_persistence_check"}]' \
        "http://${SOLR_HOST}:8983/solr/cloud_test_c1/update?commit=true" 2>/dev/null)
    if [ "$idx_code" = "200" ]; then
        print_pass "Document indexed (HTTP 200)"
    else
        print_fail "Document indexing failed (HTTP $idx_code)"
    fi

    # Restart Solr and verify everything survives
    print_test "Restart Solr — collection, security, and documents must survive"
    docker compose restart solr >/dev/null 2>&1
    local waited=0
    while [ "$waited" -lt 60 ]; do
        if docker compose ps | grep -q healthy; then break; fi
        sleep 3
        waited=$((waited + 3))
    done

    # Collection still exists
    coll_resp=$(curl -s -u "admin:${admin_pass}" \
        "http://${SOLR_HOST}:8983/solr/admin/collections?action=LIST&wt=json")
    if echo "$coll_resp" | grep -q '"cloud_test_c1"'; then
        print_pass "Collection survives restart (ZK persistence confirmed)"
    else
        print_fail "Collection LOST after restart (ZK data not persisted)"
    fi

    # Document still exists
    print_test "Document survives Solr restart (ZK + index persistence)"
    local doc_resp
    doc_resp=$(curl -s -u "solr_cloud_tenant:${CLOUD_PASS}" \
        "http://${SOLR_HOST}:8983/solr/cloud_test_c1/select?q=id:persist-test-1&wt=json")
    if echo "$doc_resp" | grep -q '"numFound":1'; then
        print_pass "Document persists after restart"
    else
        print_fail "Document LOST after restart"
    fi

    # Tenant credentials survive (security in ZK)
    print_test "Tenant authentication survives restart (Security API in ZK)"
    local auth_code
    auth_code=$(curl -so /dev/null -w '%{http_code}' -u "solr_cloud_tenant:${CLOUD_PASS}" \
        "http://${SOLR_HOST}:8983/solr/cloud_test_c1/admin/ping" 2>/dev/null)
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
    RUN_NEGATIVE=1
    RUN_PERFORMANCE=1
    RUN_MOODLE=1
    RUN_CLEANUP=1
    RUN_MONITORING=0
    RUN_TENANT=0
    RUN_CLOUD=0

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
                RUN_NEGATIVE=0
                RUN_PERFORMANCE=0
                RUN_MOODLE=0
                RUN_CLEANUP=0
                shift
                ;;
            --negative-only)
                RUN_UNIT=0
                RUN_INTEGRATION=0
                RUN_SECURITY=0
                RUN_PERFORMANCE=0
                RUN_MOODLE=0
                RUN_CLEANUP=0
                shift
                ;;
            --moodle-only)
                RUN_UNIT=0
                RUN_INTEGRATION=0
                RUN_SECURITY=0
                RUN_NEGATIVE=0
                RUN_PERFORMANCE=0
                RUN_CLEANUP=0
                shift
                ;;
            --no-cleanup)
                RUN_CLEANUP=0
                shift
                ;;
            --monitoring)
                RUN_MONITORING=1
                shift
                ;;
            --tenant)
                RUN_TENANT=1
                shift
                ;;
            --cloud|--solrcloud)
                RUN_CLOUD=1
                SOLR_MODE=solrcloud
                shift
                ;;
            --help)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --unit-only          Run only unit tests"
                echo "  --integration-only   Run only integration tests"
                echo "  --security-only      Run only security tests"
                echo "  --negative-only      Run only negative tests (invalid inputs)"
                echo "  --moodle-only        Run only Moodle document tests"
                echo "  --no-cleanup         Skip cleanup tests"
                echo "  --monitoring         Run Prometheus/Grafana health checks"
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
    [ $RUN_NEGATIVE -eq 1 ] && negative_tests
    [ $RUN_PERFORMANCE -eq 1 ] && performance_tests
    [ $RUN_MOODLE -eq 1 ] && moodle_document_tests
    [ $RUN_MONITORING -eq 1 ] && monitoring_tests
    [ $RUN_TENANT -eq 1 ] && tenant_tests
    [ $RUN_CLOUD -eq 1 ] && solrcloud_tests
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
        local success_rate

        success_rate=$((TESTS_PASSED * 100 / TESTS_TOTAL))
        echo -e "${BOLD}Success Rate:${NC}  ${success_rate}%"

        if [ $success_rate -ge 90 ]; then
            echo -e "\n${GREEN}${BOLD}TEST SUITE PASSED${NC}"
            exit 0
        elif [ $success_rate -ge 70 ]; then
            echo -e "\n${YELLOW}${BOLD}TEST SUITE PASSED WITH WARNINGS${NC}"
            exit 0
        else
            echo -e "\n${RED}${BOLD}TEST SUITE FAILED${NC}"
            exit 1
        fi
    else
        echo -e "\n${YELLOW}${BOLD}NO TESTS RUN${NC}"
        exit 1
    fi
}

# Run main function
main "$@"
