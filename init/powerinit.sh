#!/bin/bash
# Copyright (c) 2026 Eledia GmbH / Bernd Schreistetter
# SPDX-License-Identifier: MIT
# Version: v3.4.6

# =========================================
# Solr Init Container — Multi-Tenant
# Developer: BSC Bernd Schreistetter
# Company: Eledia.de
# Version: v3.4.6
# =========================================
# Runs as init container (exit 0 = Solr starts, exit != 0 = Solr blocked)
# Rebuilds security.json COMPLETELY on every start from:
#   - .env (admin + support credentials)
#   - /opt/solr/tenants.env (all tenant configurations)

set -euo pipefail

# ---------------------------------------------------------------------------
# Logging — stdout + /var/log/solr/setup.log
# ---------------------------------------------------------------------------
LOG_DIR="${LOG_DIR:-/var/log/solr}"
LOG_FILE="${LOG_DIR}/setup.log"

# _log: Write a timestamped message to stdout and $LOG_FILE.
# Args: $@ - message text
# Returns: nothing
_log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] %s\n' "$ts" "$*"
  printf '[%s] %s\n' "$ts" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# _setup_logging: Create log directory and file, write start banner.
# Args: none
# Returns: nothing; exits cleanly if directory creation fails (non-fatal with || true)
_setup_logging() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  touch "$LOG_FILE" 2>/dev/null || true
  _log "=== powerinit.sh started ==="
}

_setup_logging

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
DATA_DIR="/var/solr/data"
CONFIGSET_SRC="/config"
CONFIGSET_DST="${DATA_DIR}/configsets/eLeDia-moodle-tenant/conf"
DEFAULT_CONFIGSET_DST="${DATA_DIR}/configsets/_default/conf"
TENANTS_ENV="/opt/solr/tenants.env"
ENV_FILE_PATH="${ENV_FILE_PATH:-/.env}"

# Init state tracking (install vs upgrade/update)
STATE_DIR="${DATA_DIR}/.eledia-init"
STATE_FILE="${STATE_DIR}/state.env"
APPLY_MARKER_FILE="${DATA_DIR}/.eledia-apply-required"
INIT_MODE="install"
PREV_TENANTS_SHA=""
PREV_CONFIG_SHA=""
CURRENT_TENANTS_SHA=""
CURRENT_CONFIG_SHA=""

# ---------------------------------------------------------------------------
# Load .env
# ---------------------------------------------------------------------------
# load_env: Source a .env file into the current shell environment with export (-a).
# Args: $1 - absolute path to the env file
# Returns: nothing; silently skips if the file does not exist
load_env() {
  if [ -f "$1" ]; then
    _log "Loading environment from $1"
    set -a
    # shellcheck disable=SC1090
    . "$1"
    set +a
  fi
}

if [ -f "$ENV_FILE_PATH" ]; then
  load_env "$ENV_FILE_PATH"
else
  _log "WARNING: No .env found at $ENV_FILE_PATH"
fi

# _sha256_file: Return sha256 for file content, or 'missing' if absent.
_sha256_file() {
  local file="$1"
  if [ -f "$file" ]; then
    sha256sum "$file" | awk '{print $1}'
  else
    printf 'missing'
  fi
}

# _sha256_config: Hash relevant config files that define default configset behavior.
_sha256_config() {
  local schema_cfg solr_cfg
  schema_cfg="$(_sha256_file "${CONFIGSET_SRC}/managed-schema")"
  solr_cfg="$(_sha256_file "${CONFIGSET_SRC}/solrconfig.xml")"
  printf '%s|%s' "$schema_cfg" "$solr_cfg" | sha256sum | awk '{print $1}'
}

# _load_previous_state: Read persisted init state if available.
_load_previous_state() {
  if [ -f "$STATE_FILE" ]; then
    PREV_TENANTS_SHA="$(grep -E '^TENANTS_SHA=' "$STATE_FILE" | head -n1 | cut -d'=' -f2- || true)"
    PREV_CONFIG_SHA="$(grep -E '^CONFIG_SHA=' "$STATE_FILE" | head -n1 | cut -d'=' -f2- || true)"
    INIT_MODE="upgrade"
  else
    INIT_MODE="install"
  fi
}

# _save_state: Persist current hashes for next run comparison.
_save_state() {
  mkdir -p "$STATE_DIR"
  cat > "$STATE_FILE" <<EOF
TENANTS_SHA=${CURRENT_TENANTS_SHA}
CONFIG_SHA=${CURRENT_CONFIG_SHA}
LAST_MODE=${INIT_MODE}
LAST_RUN_AT=$(date '+%Y-%m-%dT%H:%M:%S%z')
EOF
}

# _mark_apply_required: Signal runtime container that tenant apply is required.
_mark_apply_required() {
  mkdir -p "$STATE_DIR"
  touch "$APPLY_MARKER_FILE"
  chmod 640 "$APPLY_MARKER_FILE" 2>/dev/null || true
  chown 8983:8983 "$APPLY_MARKER_FILE" 2>/dev/null || true
}

_load_previous_state
CURRENT_TENANTS_SHA="$(_sha256_file "$TENANTS_ENV")"
CURRENT_CONFIG_SHA="$(_sha256_config)"

if [ "$INIT_MODE" = "install" ]; then
  _log "Init mode detected: install (no previous state)"
else
  if [ "$CURRENT_TENANTS_SHA" != "$PREV_TENANTS_SHA" ] || [ "$CURRENT_CONFIG_SHA" != "$PREV_CONFIG_SHA" ]; then
    INIT_MODE="upgrade"
    _log "Init mode detected: upgrade/update (inputs changed)"
    _log "  tenants.env changed: $([ "$CURRENT_TENANTS_SHA" != "$PREV_TENANTS_SHA" ] && echo yes || echo no)"
    _log "  eLeDia-config changed: $([ "$CURRENT_CONFIG_SHA" != "$PREV_CONFIG_SHA" ] && echo yes || echo no)"
  else
    INIT_MODE="steady"
    _log "Init mode detected: steady-state (no material input changes)"
  fi
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# _validate_name: Reject names that contain characters outside [a-zA-Z0-9_].
# Args: $1 - name to validate, $2 - human-readable label for error messages
# Returns: nothing on success; exits with code 4 on invalid input
_validate_name() {
  local name="$1" label="$2"
  case "$name" in
    *[!a-zA-Z0-9_]*)
      _log "ERROR: Invalid $label '$name' — only alphanumeric and underscore allowed"
      exit 4
      ;;
  esac
}

# base64 command (portable)
if base64 --help 2>&1 | grep -q 'wrap'; then
  _BASE64="base64 -w0"
else
  _BASE64="base64"
fi

# hash_solr_password: Produce a Solr BasicAuthPlugin-compatible credential string.
# Algorithm: base64(SHA256(SHA256(random_salt || password))) + " " + base64(salt)
# The credential string is stored verbatim in security.json under authentication.credentials.
# Args: $1 - plaintext password
# Returns: prints "<hash_b64> <salt_b64>" to stdout; exits non-zero on openssl failure
hash_solr_password() {
  local pass="$1"
  local salt_file pass_file combined hash1 hash2
  salt_file="$(mktemp)"
  pass_file="$(mktemp)"
  combined="$(mktemp)"
  hash1="$(mktemp)"
  hash2="$(mktemp)"
  chmod 600 "$salt_file" "$pass_file" "$combined" "$hash1" "$hash2"

  openssl rand 32 > "$salt_file"
  printf '%s' "$pass" > "$pass_file"
  cat "$salt_file" "$pass_file" > "$combined"
  openssl dgst -sha256 -binary "$combined" > "$hash1"
  openssl dgst -sha256 -binary "$hash1" > "$hash2"

  local hash_b64 salt_b64
  hash_b64="$($_BASE64 < "$hash2" | tr -d '\n\r')"
  salt_b64="$($_BASE64 < "$salt_file" | tr -d '\n\r')"

  # Zero out before delete
  dd if=/dev/zero of="$pass_file" bs=1 count="$(wc -c < "$pass_file")" 2>/dev/null || true
  dd if=/dev/zero of="$combined" bs=1 count="$(wc -c < "$combined")" 2>/dev/null || true
  rm -f "$salt_file" "$pass_file" "$combined" "$hash1" "$hash2"

  printf '%s %s' "$hash_b64" "$salt_b64"
}

# gen_password: Generate a random 32-character alphanumeric password via openssl.
# Args: none
# Returns: prints 32-character string to stdout (no newline from head -c)
gen_password() {
  openssl rand -base64 36 | tr -d '/+=' | head -c 32
}

# ---------------------------------------------------------------------------
# Step 0: Validate required env vars
# ---------------------------------------------------------------------------
_log "Step 0: Validating environment"

ADMIN_USER="${SOLR_ADMIN_USER:-admin}"
SUPPORT_USER="${SOLR_SUPPORT_USER:-support}"

if [ -z "${SOLR_ADMIN_PASSWORD:-}" ] || echo "${SOLR_ADMIN_PASSWORD:-}" | grep -qi "CHANGE_ME"; then
  _log "ERROR: SOLR_ADMIN_PASSWORD is missing or still contains CHANGE_ME. Run ./setup.sh or set a real password in .env."
  exit 1
fi

if [ -z "${SOLR_SUPPORT_PASSWORD:-}" ] || echo "${SOLR_SUPPORT_PASSWORD:-}" | grep -qi "CHANGE_ME"; then
  _log "ERROR: SOLR_SUPPORT_PASSWORD is missing or still contains CHANGE_ME. Run ./setup.sh or set a real password in .env."
  exit 1
fi

_validate_name "$ADMIN_USER" "SOLR_ADMIN_USER"
_validate_name "$SUPPORT_USER" "SOLR_SUPPORT_USER"
_log "  Admin user: $ADMIN_USER, Support user: $SUPPORT_USER"

# ---------------------------------------------------------------------------
# Step 1: Load tenants.env
# ---------------------------------------------------------------------------
_log "Step 1: Loading tenants.env"

if [ ! -f "$TENANTS_ENV" ]; then
  _log "  No tenants.env found at $TENANTS_ENV — creating empty file"
  touch "$TENANTS_ENV" 2>/dev/null || true
fi

# Parse tenants into arrays.
# Explicit =() initialization is required — in bash 5.2 on Alpine, declare-only
# (without assignment) does not mark a variable as "set" for set -u purposes.
TENANT_NAMES=()
TENANT_COUNT=0
declare -A TENANT_CORES=() TENANT_USER=() TENANT_PASS=() TENANT_ACTIVE=()

# _load_tenants: Parse tenants.env and populate the TENANT_* associative arrays.
# Reads TENANT_<name>_CORES, TENANT_<name>_USER, TENANT_<name>_PASS, TENANT_<name>_ACTIVE.
# Maintains TENANT_NAMES (ordered) and TENANT_COUNT.
# Args: none (reads $TENANTS_ENV)
# Returns: populates global arrays; no output
_load_tenants() {
  local key value name field _dup _n
  while IFS='=' read -r key value; do
    # Skip comments and empty lines
    case "$key" in
      '#'*|'') continue ;;
    esac
    # Match TENANT_<name>_<FIELD>
    if echo "$key" | grep -qE '^TENANT_[A-Za-z0-9_]+_(CORES|USER|PASS|ACTIVE)$'; then
      # Extract name and field
      name="${key#TENANT_}"
      field="${name##*_}"
      name="${name%_*}"
      case "$field" in
        CORES)
          TENANT_CORES["$name"]="$value"
          _dup=0
          for _n in "${TENANT_NAMES[@]+"${TENANT_NAMES[@]}"}"; do
            [ "$_n" = "$name" ] && { _dup=1; break; }
          done
          if [ "$_dup" -eq 0 ]; then
            TENANT_NAMES+=("$name")
            ((TENANT_COUNT++)) || true
          fi
          ;;
        USER)   TENANT_USER["$name"]="$value" ;;
        PASS)   TENANT_PASS["$name"]="$value" ;;
        ACTIVE) TENANT_ACTIVE["$name"]="$value" ;;
      esac
    fi
  done < "$TENANTS_ENV"
}

_load_tenants
_log "  Found $TENANT_COUNT tenant(s)"

# ---------------------------------------------------------------------------
# Step 2: Create configsets (idempotent)
# ---------------------------------------------------------------------------
_log "Step 2: Configset eLeDia-moodle-tenant + _default"

if [ -d "$CONFIGSET_DST" ]; then
  _log "  Configset eLeDia-moodle-tenant already exists — refreshing managed-schema + solrconfig.xml"
  cp -f "${CONFIGSET_SRC}/managed-schema" "${CONFIGSET_DST}/managed-schema"
  cp -f "${CONFIGSET_SRC}/solrconfig.xml" "${CONFIGSET_DST}/solrconfig.xml"
else
  _log "  Creating configset eLeDia-moodle-tenant from $CONFIGSET_SRC"
  mkdir -p "$CONFIGSET_DST"
  if ! cp -a "${CONFIGSET_SRC}/." "${CONFIGSET_DST}/"; then
    _log "ERROR: Failed to copy config files to eLeDia-moodle-tenant configset"
    exit 2
  fi
  _log "  Configset eLeDia-moodle-tenant created at $CONFIGSET_DST"
fi

# Also enforce Moodle-capable _default so plain Core CREATE without explicit
# configSet stays Moodle-compatible.
if [ -d "$DEFAULT_CONFIGSET_DST" ]; then
  _log "  Configset _default already exists — refreshing managed-schema + solrconfig.xml"
  cp -f "${CONFIGSET_SRC}/managed-schema" "${DEFAULT_CONFIGSET_DST}/managed-schema"
  cp -f "${CONFIGSET_SRC}/solrconfig.xml" "${DEFAULT_CONFIGSET_DST}/solrconfig.xml"
else
  _log "  Creating configset _default from $CONFIGSET_SRC"
  mkdir -p "$DEFAULT_CONFIGSET_DST"
  if ! cp -a "${CONFIGSET_SRC}/." "${DEFAULT_CONFIGSET_DST}/"; then
    _log "ERROR: Failed to copy config files to _default configset"
    exit 2
  fi
  _log "  Configset _default created at $DEFAULT_CONFIGSET_DST"
fi

chown -R 8983:8983 "${DATA_DIR}/configsets" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 3: Regenerate security.json completely
# ---------------------------------------------------------------------------
_log "Step 3: Generating security.json"

mkdir -p "$DATA_DIR"

# Hash admin + support
_log "  Hashing admin credentials..."
ADMIN_HASH="$(hash_solr_password "${SOLR_ADMIN_PASSWORD}")"
SUPPORT_HASH="$(hash_solr_password "${SOLR_SUPPORT_PASSWORD}")"

# Start building security.json from template
TEMPLATE="/init/security.json.template"
if [ ! -f "$TEMPLATE" ]; then
  _log "ERROR: security.json.template not found at $TEMPLATE"
  exit 2
fi

# Replace admin/support placeholders
TMP_SEC="$(mktemp)"
chmod 600 "$TMP_SEC"
sed \
  -e "s|__ADMIN_USER__|${ADMIN_USER}|g" \
  -e "s|__SUPPORT_USER__|${SUPPORT_USER}|g" \
  -e "s|__ADMIN_HASH__|${ADMIN_HASH}|g" \
  -e "s|__SUPPORT_HASH__|${SUPPORT_HASH}|g" \
  "$TEMPLATE" > "$TMP_SEC"

# Template contains the fallback `all` permission for the static baseline. Remove
# it before adding dynamic Moodle/tenant permissions and append it exactly once
# at the end after all specific rules. Solr evaluates permissions in order; an
# early `all` rule shadows later tenant permissions.
TMP2="$(mktemp)"
chmod 600 "$TMP2"
jq '(.authorization.permissions) |= map(select(.name != "all"))' "$TMP_SEC" > "$TMP2"
mv "$TMP2" "$TMP_SEC"

# Legacy moodle user (backward compatibility — used when system_type=moodle)
MOODLE_USER="${SOLR_MOODLE_USER:-}"
MOODLE_PASS="${SOLR_MOODLE_PASSWORD:-}"
LEGACY_CORE="${SOLR_CORE_NAME:-moodle_core}"

if [ -n "$MOODLE_USER" ] && [ -n "$MOODLE_PASS" ]; then
  _log "  Adding legacy moodle user: $MOODLE_USER (core: $LEGACY_CORE)"
  MOODLE_HASH="$(hash_solr_password "$MOODLE_PASS")"

  TMP2="$(mktemp)"
  chmod 600 "$TMP2"
  jq --arg u "$MOODLE_USER" --arg h "$MOODLE_HASH" \
    '.authentication.credentials[$u] = $h' "$TMP_SEC" > "$TMP2"
  mv "$TMP2" "$TMP_SEC"

  TMP2="$(mktemp)"
  chmod 600 "$TMP2"
  jq --arg u "$MOODLE_USER" \
    '.authorization["user-role"][$u] = "moodle"' "$TMP_SEC" > "$TMP2"
  mv "$TMP2" "$TMP_SEC"

  TMP2="$(mktemp)"
  chmod 600 "$TMP2"
  jq --arg c "$LEGACY_CORE" \
    '.authorization.permissions += [{
      "name": "moodle-core-read",
      "role": ["admin","support","moodle"],
      "collection": [$c],
      "path": ["/select","/admin/ping","/admin/system","/admin/system/","/schema","/schema/*","/replication"]
    }]' "$TMP_SEC" > "$TMP2"
  mv "$TMP2" "$TMP_SEC"

  TMP2="$(mktemp)"
  chmod 600 "$TMP2"
  jq --arg c "$LEGACY_CORE" \
    '.authorization.permissions += [{
      "name": "moodle-core-write",
      "role": ["admin","moodle"],
      "collection": [$c],
      "path": ["/update","/update/extract"]
    }]' "$TMP_SEC" > "$TMP2"
  mv "$TMP2" "$TMP_SEC"
fi

# Merge each active tenant using jq
for tenant_name in "${TENANT_NAMES[@]+"${TENANT_NAMES[@]}"}"; do
  active="${TENANT_ACTIVE[$tenant_name]:-true}"
  [ "$active" = "false" ] && continue

  user="${TENANT_USER[$tenant_name]:-solr_${tenant_name}}"
  pass="${TENANT_PASS[$tenant_name]:-}"
  cores="${TENANT_CORES[$tenant_name]:-}"

  if [ -z "$pass" ]; then
    _log "  WARNING: No password for tenant $tenant_name — skipping"
    continue
  fi

  _validate_name "$tenant_name" "tenant name"
  _validate_name "$user" "tenant user"

  _log "  Processing tenant: $tenant_name (user: $user, cores: $cores)"
  tenant_hash="$(hash_solr_password "$pass")"
  if [ "${SOLR_MODE:-}" = "solrcloud" ]; then
    role="tenant-${tenant_name}"
  else
    role="tenant"
  fi

  TMP2="$(mktemp)"
  chmod 600 "$TMP2"
  jq --arg u "$user" --arg h "$tenant_hash" \
    '.authentication.credentials[$u] = $h' "$TMP_SEC" > "$TMP2"
  mv "$TMP2" "$TMP_SEC"

  TMP2="$(mktemp)"
  chmod 600 "$TMP2"
  jq --arg u "$user" --arg r "$role" \
    'if $r == "tenant" then
       .authorization["user-role"][$u] = $r
     else
       .authorization["user-role"][$u] = ["tenant", $r]
     end' "$TMP_SEC" > "$TMP2"
  mv "$TMP2" "$TMP_SEC"

  if [ "${SOLR_MODE:-}" = "solrcloud" ]; then
    IFS=',' read -ra CORE_ARRAY <<< "$cores"
    for core in "${CORE_ARRAY[@]}"; do
      core="$(echo "$core" | tr -d ' ')"
      [ -z "$core" ] && continue

      TMP2="$(mktemp)"; chmod 600 "$TMP2"
      jq --arg n "tenant-${tenant_name}-${core}-read" --arg r "$role" --arg c "$core" \
        '.authorization.permissions += [{
          "name": $n,
          "role": ["admin","support",$r],
          "collection": [$c],
          "path": ["/select","/admin/ping","/admin/system","/admin/system/","/schema","/schema/*","/replication"]
        }]' "$TMP_SEC" > "$TMP2"
      mv "$TMP2" "$TMP_SEC"

      TMP2="$(mktemp)"; chmod 600 "$TMP2"
      jq --arg n "tenant-${tenant_name}-${core}-write" --arg r "$role" --arg c "$core" \
        '.authorization.permissions += [{
          "name": $n,
          "role": ["admin",$r],
          "collection": [$c],
          "path": ["/update","/update/extract"]
        }]' "$TMP_SEC" > "$TMP2"
      mv "$TMP2" "$TMP_SEC"
    done
  fi
done

if [ "${SOLR_MODE:-}" != "solrcloud" ] && [ "$TENANT_COUNT" -gt 0 ]; then
  _log "  Adding standalone shared tenant-read and tenant-write permissions"

  TMP2="$(mktemp)"; chmod 600 "$TMP2"
  jq '.authorization.permissions += [{
    "name": "tenant-read",
    "role": ["admin","support","tenant"],
    "path": ["/select","/admin/ping","/admin/system","/admin/system/","/schema","/schema/*","/replication"]
  }]' "$TMP_SEC" > "$TMP2"
  mv "$TMP2" "$TMP_SEC"

  TMP2="$(mktemp)"; chmod 600 "$TMP2"
  jq '.authorization.permissions += [{
    "name": "tenant-write",
    "role": ["admin","tenant"],
    "path": ["/update","/update/extract"]
  }]' "$TMP_SEC" > "$TMP2"
  mv "$TMP2" "$TMP_SEC"
fi

for tenant_name in "${TENANT_NAMES[@]+"${TENANT_NAMES[@]}"}"; do
  active="${TENANT_ACTIVE[$tenant_name]:-true}"
  [ "$active" != "false" ] && continue

  user="${TENANT_USER[$tenant_name]:-solr_${tenant_name}}"
  _log "  Inactive tenant $tenant_name (user: $user) — adding blocked credential"
  blocked_pass="$(gen_password)"
  blocked_hash="$(hash_solr_password "$blocked_pass")"
  TMP2="$(mktemp)"
  chmod 600 "$TMP2"
  jq --arg u "$user" --arg h "$blocked_hash" \
    '.authentication.credentials[$u] = $h' "$TMP_SEC" > "$TMP2"
  mv "$TMP2" "$TMP_SEC"
done

if ! jq . "$TMP_SEC" > /dev/null 2>&1; then
  _log "ERROR: Generated security.json is not valid JSON"
  rm -f "$TMP_SEC"
  exit 1
fi

TMP2="$(mktemp)"
chmod 600 "$TMP2"
jq '.authorization.permissions += [{"name":"all","role":"admin"}]' "$TMP_SEC" > "$TMP2"
mv "$TMP2" "$TMP_SEC"

mv "$TMP_SEC" "${DATA_DIR}/security.json"
chmod 600 "${DATA_DIR}/security.json"
chown 8983:8983 "${DATA_DIR}/security.json" 2>/dev/null || true

jq 'del(.authentication.credentials) | . + {"note": "credentials removed from backup"}' \
  "${DATA_DIR}/security.json" > "${LOG_DIR}/security.json.bak" 2>/dev/null || true

_log "  security.json written ($(jq '.authorization.permissions | length' "${DATA_DIR}/security.json") permissions)"

# ---------------------------------------------------------------------------
# Step 4: Pre-create core directories for active tenants (standalone only)
# ---------------------------------------------------------------------------
SOLR_MODE="${SOLR_MODE:-}"
if [ "$SOLR_MODE" = "solrcloud" ]; then
  _log "Step 4: SolrCloud mode — skipping core directory pre-creation (Collections API handles this)"
fi
_log "Step 4: Pre-creating core directories"

if [ "$SOLR_MODE" != "solrcloud" ]; then
for tenant_name in "${TENANT_NAMES[@]+"${TENANT_NAMES[@]}"}"; do
  active="${TENANT_ACTIVE[$tenant_name]:-true}"
  [ "$active" = "false" ] && continue

  cores="${TENANT_CORES[$tenant_name]:-}"
  IFS=',' read -ra CORE_ARRAY <<< "$cores"
  for core in "${CORE_ARRAY[@]}"; do
    core="$(echo "$core" | tr -d ' ')"
    [ -z "$core" ] && continue
    core_dir="${DATA_DIR}/${core}"

    if [ -f "${core_dir}/core.properties" ]; then
      _log "  Core '$core' already exists — skipping"
      continue
    fi

    _log "  Pre-creating core directory: $core"
    mkdir -p "${core_dir}/conf"
    if ! cp -a "${CONFIGSET_SRC}/." "${core_dir}/conf/"; then
      _log "ERROR: Failed to copy config for core $core"
      exit 2
    fi
    printf 'name=%s\n' "$core" > "${core_dir}/core.properties"
    chown -R 8983:8983 "${core_dir}" 2>/dev/null || true
    _log "  Core '$core' directory created"
  done
done
fi

if [ "$SOLR_MODE" != "solrcloud" ] && [ -n "$MOODLE_USER" ] && [ -n "$MOODLE_PASS" ] && [ -n "$LEGACY_CORE" ]; then
  core_dir="${DATA_DIR}/${LEGACY_CORE}"
  if [ -f "${core_dir}/core.properties" ]; then
    _log "  Legacy core '$LEGACY_CORE' already exists — skipping"
  else
    _log "  Pre-creating legacy core directory: $LEGACY_CORE"
    mkdir -p "${core_dir}/conf"
    if ! cp -a "${CONFIGSET_SRC}/." "${core_dir}/conf/"; then
      _log "ERROR: Failed to copy config for legacy core $LEGACY_CORE"
      exit 2
    fi
    printf 'name=%s\n' "$LEGACY_CORE" > "${core_dir}/core.properties"
    chown -R 8983:8983 "${core_dir}" 2>/dev/null || true
    _log "  Legacy core '$LEGACY_CORE' directory created"
  fi
fi

# ---------------------------------------------------------------------------
# Step 5: Fix permissions
# ---------------------------------------------------------------------------
_log "Step 5: Fixing permissions"

chown -R 8983:8983 "${DATA_DIR}" 2>/dev/null || true
chmod -R 750 "${DATA_DIR}" 2>/dev/null || true
find "${DATA_DIR}" -type f -exec chmod 640 {} \; 2>/dev/null || true
chmod 600 "${DATA_DIR}/security.json" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 6: Final validation
# ---------------------------------------------------------------------------
_log "Step 6: Validation"

if [ ! -s "${DATA_DIR}/security.json" ]; then
  _log "ERROR: security.json is missing or empty"
  exit 1
fi

if ! jq . "${DATA_DIR}/security.json" > /dev/null 2>&1; then
  _log "ERROR: security.json is not valid JSON"
  exit 1
fi

perm_count="$(jq '.authorization.permissions | length' "${DATA_DIR}/security.json")"
cred_count="$(jq '.authentication.credentials | length' "${DATA_DIR}/security.json")"
_log "  Permissions: $perm_count, Credentials: $cred_count"

# Persist mode/hash state and signal runtime apply when needed.
if [ "$INIT_MODE" = "install" ] || [ "$INIT_MODE" = "upgrade" ]; then
  _mark_apply_required
  _log "  Marked tenant apply as required for runtime container"
fi

_save_state
_log "  State saved: mode=${INIT_MODE}, tenants_sha=${CURRENT_TENANTS_SHA}, config_sha=${CURRENT_CONFIG_SHA}"

sync
sleep 1

_log "=== powerinit.sh completed successfully ==="
