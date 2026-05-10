#!/bin/bash
# =========================================
# Solr Init Container — Multi-Tenant
# Developer: BSC Bernd Schreistetter
# Company: Eledia.de
# Version: v3.0.0
# =========================================
# Runs as init container (exit 0 = Solr starts, exit != 0 = Solr blocked)
# Rebuilds security.json COMPLETELY on every start from:
#   - .env (admin + support credentials)
#   - /opt/solr/tenants.env (all tenant configurations)

set -euo pipefail

# ---------------------------------------------------------------------------
# Logging — stdout + /var/log/solr/setup.log
# ---------------------------------------------------------------------------
LOG_DIR="/var/log/solr"
LOG_FILE="${LOG_DIR}/setup.log"

_log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] %s\n' "$ts" "$*" | tee -a "$LOG_FILE"
}

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
CONFIGSET_DST="${DATA_DIR}/configsets/moodle-tenant/conf"
TENANTS_ENV="/opt/solr/tenants.env"
ENV_FILE_PATH="${ENV_FILE_PATH:-/.env}"

# ---------------------------------------------------------------------------
# Load .env
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Validate names: only [a-z0-9_] allowed
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

# Solr BasicAuth double-SHA256 hash
# Format: base64(SHA256(SHA256(salt || password))) base64(salt)
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

# Generate a random 32-char password
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
  SOLR_ADMIN_PASSWORD="$(gen_password)"
  _log "  Generated SOLR_ADMIN_PASSWORD"
fi

if [ -z "${SOLR_SUPPORT_PASSWORD:-}" ] || echo "${SOLR_SUPPORT_PASSWORD:-}" | grep -qi "CHANGE_ME"; then
  SOLR_SUPPORT_PASSWORD="$(gen_password)"
  _log "  Generated SOLR_SUPPORT_PASSWORD"
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
# Step 2: Create configset (idempotent)
# ---------------------------------------------------------------------------
_log "Step 2: Configset moodle-tenant"

if [ -d "$CONFIGSET_DST" ]; then
  _log "  Configset already exists — skipping"
else
  _log "  Creating configset from $CONFIGSET_SRC"
  mkdir -p "$CONFIGSET_DST"
  if ! cp -a "${CONFIGSET_SRC}/." "${CONFIGSET_DST}/"; then
    _log "ERROR: Failed to copy config files to configset"
    exit 2
  fi
  _log "  Configset created at $CONFIGSET_DST"
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

# Legacy moodle user (backward compatibility — used when system_type=moodle)
# If SOLR_MOODLE_USER + SOLR_MOODLE_PASSWORD are both set in .env, create a
# dedicated moodle user with full access to SOLR_CORE_NAME.
# In multi-tenant deployments these vars are still present for compat; having
# the moodle user in Solr with access only to SOLR_CORE_NAME is harmless.
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
      "name": "moodle-core-access",
      "role": ["admin","support","moodle"],
      "collection": [$c],
      "path": ["/select","/update","/update/extract","/admin/ping","/schema","/schema/*","/replication"]
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
  role="tenant-${tenant_name}"

  # Add credential
  TMP2="$(mktemp)"
  chmod 600 "$TMP2"
  jq --arg u "$user" --arg h "$tenant_hash" \
    '.authentication.credentials[$u] = $h' "$TMP_SEC" > "$TMP2"
  mv "$TMP2" "$TMP_SEC"

  # Add user-role mapping
  TMP2="$(mktemp)"
  chmod 600 "$TMP2"
  jq --arg u "$user" --arg r "$role" \
    '.authorization["user-role"][$u] = $r' "$TMP_SEC" > "$TMP2"
  mv "$TMP2" "$TMP_SEC"

  # Add one permission entry per core
  IFS=',' read -ra CORE_ARRAY <<< "$cores"
  for core in "${CORE_ARRAY[@]}"; do
    core="$(echo "$core" | tr -d ' ')"
    [ -z "$core" ] && continue
    perm_name="tenant-${tenant_name}-${core}"

    TMP2="$(mktemp)"
    chmod 600 "$TMP2"
    jq --arg n "$perm_name" --arg r "$role" --arg c "$core" \
      '.authorization.permissions += [{
        "name": $n,
        "role": ["admin","support",$r],
        "collection": [$c],
        "path": ["/select","/update","/update/extract","/admin/ping","/schema","/schema/*","/replication"]
      }]' "$TMP_SEC" > "$TMP2"
    mv "$TMP2" "$TMP_SEC"
  done
done

# Inactive tenants: add credential with random hash (blocks login, keeps user visible)
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

# Validate JSON
if ! jq . "$TMP_SEC" > /dev/null 2>&1; then
  _log "ERROR: Generated security.json is not valid JSON"
  rm -f "$TMP_SEC"
  exit 1
fi

# Write final file
mv "$TMP_SEC" "${DATA_DIR}/security.json"
chmod 600 "${DATA_DIR}/security.json"
chown 8983:8983 "${DATA_DIR}/security.json" 2>/dev/null || true

# Save sanitized backup (credential values replaced for safety)
jq 'del(.authentication.credentials) | . + {"note": "credentials removed from backup"}' \
  "${DATA_DIR}/security.json" > "${LOG_DIR}/security.json.bak" 2>/dev/null || true

_log "  security.json written ($(jq '.authorization.permissions | length' "${DATA_DIR}/security.json") permissions)"

# ---------------------------------------------------------------------------
# Step 4: Pre-create core directories for active tenants
# ---------------------------------------------------------------------------
_log "Step 4: Pre-creating core directories"

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

# Legacy core pre-creation (backward compat — when SOLR_MOODLE_USER/PASSWORD are set)
if [ -n "$MOODLE_USER" ] && [ -n "$MOODLE_PASS" ] && [ -n "$LEGACY_CORE" ]; then
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

# Sensitive files need 600 (override recursive chmod above)
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

sync
sleep 1

_log "=== powerinit.sh completed successfully ==="
