#!/bin/bash
# Copyright (c) 2026 eLeDia.de / Bernd Schreistetter (bsc)
# Version: v3.4.9
#
# eLeDia Unit Tests — file checks, compose config, Dockerfile
# Part of the eLeDia Solr Multi-Tenant Docker Stack.
# Sourced by run-tests.sh — do not run directly.

# shellcheck disable=SC2153  # Variables are initialized by run-tests.sh/test-lib.sh before sourcing modules.
# shellcheck disable=SC2016  # Static grep patterns intentionally match literal shell variables.
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
    if awk '/^cmd_apply\(\) \{/,/^cmd_sync_sot\(\) \{/' scripts/solr-tenant-cmd.sh | \
       grep -q '_rebuild_tenant_permissions' && \
       awk '/^cmd_apply\(\) \{/,/^cmd_sync_sot\(\) \{/' scripts/solr-tenant-cmd.sh | \
       grep -q '_ensure_all_permission_last'; then
        print_pass "SolrCloud apply rebuilds tenant permissions and then moves all last"
    else
        print_fail "SolrCloud apply does not rebuild tenant permissions before all fallback"
    fi

    # Core names must be validated before they touch the API or generated config.
    print_test "Core names are validated before tenant mutations"
    if grep -q '^_validate_core_name()' scripts/solr-tenant-api.sh && \
       grep -q '^_validate_core_list()' scripts/solr-tenant-api.sh && \
       grep -q '_validate_core_list "\$cores"' scripts/solr-tenant-cmd.sh && \
       grep -q '_validate_core_name "\$core"' scripts/solr-tenant-cmd.sh; then
        print_pass "Core names are validated before create/apply/enable/passwd/caddy-config mutations"
    else
        print_fail "Core names are not validated consistently before tenant mutations"
    fi

    # Security reload timeouts must fail fast so password changes do not drift
    # away from tenants.env.
    print_test "Security reload timeouts fail fast"
    if grep -q 'return 1' scripts/solr-tenant-security.sh && \
       [ "$(grep -c 'if ! _wait_for_security_reload' scripts/solr-tenant-cmd.sh)" -ge 3 ] && \
       grep -q '_set_tenant_field "\$name" "PASS" "\$new_pass"' scripts/solr-tenant-cmd.sh; then
        print_pass "Security reload timeouts are treated as errors and PASS is persisted before waiting"
    else
        print_fail "Security reload timeouts still look soft or PASS persists too late"
    fi

    # Startup bootstrap should fail if tenant apply/sync-sot fails, rather than
    # logging a warning and continuing with a half-initialized security state.
    print_test "SolrCloud bootstrap fails hard on tenant sync errors"
    if grep -q 'run_logged_step' scripts/solr-cloud-entrypoint.sh && \
       grep -q 'ERROR: solr-tenant.sh apply failed during startup' scripts/solr-cloud-entrypoint.sh && \
       grep -q 'ERROR: solr-tenant.sh sync-sot failed during startup' scripts/solr-cloud-entrypoint.sh; then
        print_pass "Startup tenant sync errors are fatal"
    else
        print_fail "Startup tenant sync errors still look soft"
    fi

    # Orchestrators must call the first-class command instead of carrying their
    # own curl/jq authorization writer.
    print_test "Tenant permission rebuild command is public"
    if grep -q 'rebuild-permissions).*cmd_rebuild_permissions' scripts/solr-tenant.sh && \
       grep -q 'healthcheck).*cmd_healthcheck' scripts/solr-tenant.sh && \
       grep -q '^cmd_rebuild_permissions()' scripts/solr-tenant-cmd.sh && \
       grep -q '^cmd_healthcheck()' scripts/solr-tenant-cmd.sh; then
        print_pass "solr-tenant.sh exposes rebuild-permissions and healthcheck"
    else
        print_fail "solr-tenant.sh does not expose rebuild-permissions and healthcheck"
    fi

    print_test "Healthcheck skips drift on bootstrap-needed state"
    local healthcheck_bootstrap_dir repo_root
    healthcheck_bootstrap_dir="$(mktemp -d)"
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    if (
        set -euo pipefail
        cd "$repo_root"
        export SOLR_MODE=solrcloud
        export SOLR_BASE="http://localhost:8983/solr"
        export LOG_FILE="${healthcheck_bootstrap_dir}/tenant.log"
        export SECURITY_JSON="${healthcheck_bootstrap_dir}/security.json"
        export BOOTSTRAP_STATE_FILE="${healthcheck_bootstrap_dir}/state.env"
        : > "${LOG_FILE}"
        source scripts/solr-tenant-api.sh
        source scripts/solr-tenant-core.sh
        source scripts/solr-tenant-security.sh
        source scripts/solr-tenant-cmd.sh

        _load_admin_creds() {
            ADMIN_USER=admin
            ADMIN_PASS=secret
        }

        curl() {
            case "$*" in
                *"/admin/info/system"*) printf '200' ;;
                *"/admin/authentication"*) printf '404' ;;
                *) printf 'unexpected curl invocation: %s\n' "$*" >&2; return 2 ;;
            esac
        }

        drift_called_file="${healthcheck_bootstrap_dir}/drift-called"
        cmd_drift_detect() {
            touch "$drift_called_file"
            printf 'drift detection must not run during bootstrap\n' >&2
            return 1
        }

        output_file="${healthcheck_bootstrap_dir}/bootstrap.out"
        error_file="${healthcheck_bootstrap_dir}/bootstrap.err"
        set +e
        cmd_healthcheck >"$output_file" 2>"$error_file"
        health_rc=$?
        set -e
        if [ "$health_rc" -eq 0 ]; then
            grep -q 'Bootstrap needed' "$output_file"
            [ ! -e "$drift_called_file" ]
        else
            printf 'healthcheck returned non-zero during bootstrap test (%s)\n' "$health_rc" >&2
            printf '--- stdout ---\n' >&2
            cat "$output_file" >&2 || true
            printf '--- stderr ---\n' >&2
            cat "$error_file" >&2 || true
            exit 1
        fi
    ); then
        print_pass "Healthcheck reports bootstrap-needed without drift"
    else
        print_fail "Healthcheck still treats fresh instances as drift"
    fi

    print_test "docker-compose healthcheck uses tenant-aware command"
    if grep -q '/opt/solr/scripts/solr-tenant.sh healthcheck' docker-compose.yml; then
        print_pass "docker-compose healthcheck delegates to tenant-aware command"
    else
        print_fail "docker-compose healthcheck still uses a raw curl probe"
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



    # The central test orchestrator must execute the tenant command matrix when
    # --tenant is used by CI; otherwise passwd/rebuild command contracts are only
    # verified indirectly by downstream repos.
    print_test "run-tests executes tenant command matrix"
    if grep -q 'RUN_TENANT_COMMANDS=1' scripts/run-tests.sh && \
       grep -q 'test-tenant-commands.sh' scripts/run-tests.sh && \
       grep -q 'passwd "\$TENANT_A" --password' scripts/test-tenant-commands.sh; then
        print_pass "tenant command matrix is wired into run-tests and covers passwd --password"
    else
        print_fail "tenant command matrix is not wired into run-tests or misses passwd --password"
    fi

    # Dockerfile.solr copies the complete scripts/ tree into the runtime image.
    # Smart rebuild checksums must therefore include script changes, especially
    # solr-tenant-cmd.sh and related helper modules.
    print_test "upgrade smart rebuild tracks runtime scripts"
    if grep -q 'find "${ROOT_DIR}/scripts"' scripts/upgrade-docker.sh && \
       grep -q 'solr-tenant-cmd.sh' scripts/upgrade-docker.sh; then
        print_pass "upgrade-docker checksum covers runtime scripts"
    else
        print_fail "upgrade-docker checksum does not cover runtime scripts"
    fi

    print_test "security templates stay in sync"
    if cmp -s security.json.template init/security.json.template; then
        print_pass "root and init security.json.template are identical"
    else
        print_fail "security.json.template files drifted apart"
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
