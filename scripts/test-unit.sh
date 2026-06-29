#!/bin/bash
# Copyright (c) 2026 eLeDia.de / Bernd Schreistetter (bsc)
# Version: v3.4.10
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


    print_test "SolrCloud passwd restores tenant role and permissions"
    if awk '/^cmd_passwd\(\) \{/,/^\}/' scripts/solr-tenant-cmd.sh | \
       grep -q '_write_user_role' && \
       awk '/^cmd_passwd\(\) \{/,/^\}/' scripts/solr-tenant-cmd.sh | \
       grep -q '_rebuild_tenant_permissions' && \
       awk '/^cmd_passwd\(\) \{/,/^\}/' scripts/solr-tenant-cmd.sh | \
       grep -q '_ensure_all_permission_last'; then
        print_pass "passwd reapplies tenant role and SolrCloud permissions after credential changes"
    else
        print_fail "passwd does not restore SolrCloud tenant role/permissions after credential changes"
    fi

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

    # Security reload timeouts must fail fast in standalone mode. SolrCloud
    # skips the local wait because the auth state is ZooKeeper-persisted.
    print_test "Security reload timeouts fail fast"
    if grep -q 'return 1' scripts/solr-tenant-security.sh && \
       [ "$(grep -c 'if ! _wait_for_security_reload' scripts/solr-tenant-cmd.sh)" -ge 3 ] && \
       [ "$(grep -c 'if ! _is_cloud_mode; then' scripts/solr-tenant-cmd.sh)" -ge 3 ] && \
       grep -q '_set_tenant_field "\$name" "PASS" "\$new_pass"' scripts/solr-tenant-cmd.sh; then
        print_pass "Security reload timeouts are treated as errors and SolrCloud skips the local wait"
    else
        print_fail "Security reload handling still looks soft or Cloud wait guards are missing"
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
            export ADMIN_USER=admin ADMIN_PASS=secret
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



    print_test "Solr API temporary files use a private cleanup directory"
    if grep -q 'mktemp -d /tmp/solr-api.XXXXXX' scripts/solr-tenant-api.sh && \
       grep -q 'trap.*rm -rf.*api_tmp_dir' scripts/solr-tenant-api.sh && \
       ! grep -q 'mktemp /tmp/solr-api-resp' scripts/solr-tenant-api.sh; then
        print_pass "Solr API responses are isolated in a private temp directory"
    else
        print_fail "Solr API still writes response/error temp files directly in /tmp"
    fi

    print_test "Admin credential loader imports only whitelisted .env keys"
    if grep -q '^_read_env_key()' scripts/solr-tenant-api.sh && \
       grep -q '_read_env_key "/.env" "SOLR_ADMIN_PASSWORD"' scripts/solr-tenant-api.sh && \
       ! awk '/^_load_admin_creds\(\) \{/,/^\}/' scripts/solr-tenant-api.sh | grep -q 'set -a'; then
        print_pass "Admin credential loader avoids exporting arbitrary .env variables"
    else
        print_fail "Admin credential loader still sources/exports arbitrary .env variables"
    fi



    print_test "Backup credential loader imports only whitelisted .env keys"
    if grep -q '^_read_env_key()' scripts/solr-backup.sh && \
       grep -q '_read_env_key "/.env" "SOLR_ADMIN_PASSWORD"' scripts/solr-backup.sh && \
       ! awk '/^_load_admin_creds\(\) \{/,/^\}/' scripts/solr-backup.sh | grep -q 'set -a'; then
        print_pass "Backup credential loader avoids exporting arbitrary .env variables"
    else
        print_fail "Backup credential loader still sources/exports arbitrary .env variables"
    fi

    print_test "Runtime entrypoint uses Debian runuser instead of gosu"
    if grep -q 'exec runuser -u solr -- "$0" "$@"' scripts/solr-cloud-entrypoint.sh && \
       grep -q 'util-linux' Dockerfile.solr && \
       ! grep -q 'gosu' Dockerfile.solr scripts/solr-cloud-entrypoint.sh; then
        print_pass "Runtime drops privileges via runuser without gosu"
    else
        print_fail "Runtime still depends on gosu for privilege drop"
    fi

    print_test "Tenant test file permissions are not world-writable"
    if grep -q 'chmod 660 tenants.env' scripts/test-integration.sh && \
       ! grep -q 'chmod 666 tenants.env' scripts/test-integration.sh; then
        print_pass "Tenant integration test uses group-writable permissions only"
    else
        print_fail "Tenant integration test still makes tenants.env world-writable"
    fi

    print_test "Tenant dispatcher enforces Bash 4+"
    if grep -q 'BASH_VERSINFO' scripts/solr-tenant.sh && \
       grep -q 'Bash 4' scripts/solr-tenant.sh; then
        print_pass "solr-tenant.sh fails early on unsupported Bash versions"
    else
        print_fail "solr-tenant.sh has no Bash 4+ guard"
    fi

    print_test "security templates stay in sync"
    if [ ! -f security.json.template ] || [ ! -f init/security.json.template ]; then
        print_fail "security.json.template file missing (root or init copy)"
    elif cmp -s security.json.template init/security.json.template; then
        print_pass "root and init security.json.template are identical"
    else
        print_fail "security.json.template files drifted apart"
    fi



    print_test "Runtime rejects invalid Solr permission name admin"
    if grep -q '^_validate_authz_payload()' scripts/solr-tenant-core.sh && \
       grep -q 'Invalid Solr permission name.*admin' scripts/solr-tenant-core.sh && \
       grep -q '_validate_authz_payload "\$payload"' scripts/solr-tenant-core.sh && \
       grep -q '^validate_security_permissions()' init/powerinit.sh && \
       grep -q 'Generated security.json contains invalid Solr permission definitions' init/powerinit.sh; then
        print_pass "Runtime guards reject invalid permission name admin before Solr loads it"
    else
        print_fail "Runtime guards do not reject invalid permission name admin before Solr loads it"
    fi

    print_test "security templates use Solr-valid permission names"
    local predefined_permissions=(
        collection-admin-edit collection-admin-read core-admin-read core-admin-edit
        zk-read read update config-edit config-read schema-read schema-edit
        security-edit security-read metrics-read health filestore-read filestore-write
        package-edit package-read all
    )
    local invalid_permissions=0 security_template
    local name has_path has_method has_params predefined
    for security_template in security.json.template init/security.json.template; do
        while IFS=$'\t' read -r name has_path has_method has_params; do
            [ -n "$name" ] || continue
            predefined=0
            for permission_name in "${predefined_permissions[@]}"; do
                if [ "$name" = "$permission_name" ]; then
                    predefined=1
                    break
                fi
            done

            if [ "$name" = "admin" ]; then
                printf 'Invalid permission => Permission with name admin is neither a pre-defined permission nor qualifies as a custom permission (%s)\n' "$security_template" >&2
                invalid_permissions=1
            elif [ "$predefined" -eq 1 ]; then
                if [ "$has_path" = "true" ] || [ "$has_method" = "true" ] || [ "$has_params" = "true" ]; then
                    printf 'Pre-defined permission %s in %s carries custom-only keys\n' "$name" "$security_template" >&2
                    invalid_permissions=1
                fi
            elif [ "$has_path" != "true" ]; then
                printf 'Invalid permission => Permission with name %s is neither a pre-defined permission nor qualifies as a custom permission (%s)\n' "$name" "$security_template" >&2
                invalid_permissions=1
            fi
        done < <(jq -r '.authorization.permissions[]? | [.name, has("path"), has("method"), has("params")] | @tsv' "$security_template")
    done

    if [ "$invalid_permissions" -eq 0 ]; then
        print_pass "security templates do not contain invalid Solr permission names such as admin"
    else
        print_fail "security templates contain invalid Solr permission definitions"
    fi



    print_test "powerinit logs standalone core pre-creation only in standalone mode"
    if awk '/Step 4: SolrCloud mode/,/Step 5: Fixing permissions/' init/powerinit.sh | \
       grep -q 'else' && \
       awk '/Step 4: SolrCloud mode/,/Step 5: Fixing permissions/' init/powerinit.sh | \
       grep -q 'Step 4: Pre-creating core directories'; then
        print_pass "powerinit Step 4 logging is mode-specific"
    else
        print_fail "powerinit still logs standalone pre-creation while in SolrCloud mode"
    fi

    print_test "Moodle document test sources .env only once"
    if [ "$(grep -c 'source .env' scripts/test-moodle-documents.sh)" -eq 1 ]; then
        print_pass "test-moodle-documents.sh sources .env once"
    else
        print_fail "test-moodle-documents.sh still sources .env multiple times"
    fi

    print_test "Standalone direct Solr mode is documented as requiring proxy isolation"
    if grep -qi 'Standalone' README.md && \
       grep -qi 'Caddy' README.md && \
       grep -qi 'Tenant-Isolation\|Tenant isolation\|tenant isolation' README.md; then
        print_pass "Standalone isolation limitation is documented"
    else
        print_fail "Standalone direct Solr isolation limitation is not documented"
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

    print_test "release metadata points to current stack version"
    if grep -q '^STACK_VERSION=v3.4.10$' .env.example && \
       grep -q '\${STACK_VERSION:-v3.4.10}' docker-compose.yml && \
       grep -q '# Version: v3.4.10' Dockerfile && \
       grep -q '# Version: v3.4.10' scripts/solr-tenant.sh; then
        print_pass "Release metadata consistently points to v3.4.10"
    else
        print_fail "Release metadata is not consistent with v3.4.10"
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
