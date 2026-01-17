#!/bin/bash
# /init/powerinit.sh
#   - Initialize Solr data directory (security.json, Moodle core, Prometheus config)
#   - Keep passwords stable across restarts
#   - Load from external .env if provided

set -eu

apk add --no-cache openssl coreutils >/dev/null 2>&1

DATA_DIR="/var/solr/data"
CORE_NAME="${SOLR_CORE_NAME:-moodle_core}"

# Validate core name (alphanumeric, dash, underscore only - prevent directory traversal)
case "$CORE_NAME" in
  *[!A-Za-z0-9_-]*)
    echo "ERROR: Invalid CORE_NAME '$CORE_NAME'. Only alphanumeric, dash, and underscore allowed." >&2
    exit 4
    ;;
  */*)
    echo "ERROR: CORE_NAME '$CORE_NAME' cannot contain path separators." >&2
    exit 4
    ;;
esac

CONF_SRC="/config"
CORE_DIR="${DATA_DIR}/${CORE_NAME}"
CORE_CONF="${CORE_DIR}/conf"
PROM_CFG_DIR="/prometheus-config"
PROM_CFG_FILE="${PROM_CFG_DIR}/prometheus.yml"
REALM_NAME="Eledia Moodle Search"

# Validate that config source directory exists
if [ ! -d "$CONF_SRC" ]; then
  echo "ERROR: Config source directory $CONF_SRC not found" >&2
  exit 2
fi

ENV_FILE_PATH="${ENV_FILE_PATH:-/.env}"
ENV_FILE_VOLUME="${DATA_DIR}/.env"

sync_env_files() {
  local source_file="$1"
  local target_file="$2"

  if [ ! -f "$source_file" ]; then
    return 0
  fi

  if [ ! -f "$target_file" ]; then
    cp "$source_file" "$target_file"
  else
    local source_hash
    local target_hash
    source_hash="$(openssl dgst -sha256 "$source_file" | awk '{print $2}')"
    target_hash="$(openssl dgst -sha256 "$target_file" | awk '{print $2}')"
    if [ "$source_hash" != "$target_hash" ]; then
      cp "$source_file" "$target_file"
    fi
  fi

  chmod 600 "$target_file" 2>/dev/null || true
}

load_env() {
  local env_file="$1"
  if [ -f "$env_file" ]; then
    echo "→ Loading environment from $env_file"
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
    return 0
  fi
  return 1
}

# load external .env if provided, fallback to volume copy
if [ -f "$ENV_FILE_PATH" ]; then
  sync_env_files "$ENV_FILE_PATH" "$ENV_FILE_VOLUME"
  load_env "$ENV_FILE_PATH"
else
  echo "⚠ No external .env found — trying volume copy"
  if ! load_env "$ENV_FILE_VOLUME"; then
    echo "⚠ No volume .env found — using defaults"
  fi

#Helper: detect pre-hashed password (32+ hex chars or contains space salt)
is_hashed() {
  echo "$1" | grep -Eq '^[0-9a-f]{32,}$|[A-Za-z0-9+/=]+\s+[A-Za-z0-9+/=]+'
}

# Helper: create Solr-compatible BasicAuth hash
# IMPORTANT: Solr uses DOUBLE SHA256: SHA256(SHA256(salt + password))
hash_solr_basic_auth() {
  _pass="$1"
  _salt_bytes=32

  # Detect base64 command
  if base64 --help 2>&1 | grep -q 'wrap'; then
    _base64_cmd="base64 -w0"
  else
    _base64_cmd="base64"
  fi

  # Use secure temp files with mktemp
  _salt_file="$(mktemp)"
  _pass_file="$(mktemp)"
  _combined_file="$(mktemp)"
  _hash1_file="$(mktemp)"
  _hash2_file="$(mktemp)"
  chmod 600 "$_salt_file" "$_pass_file" "$_combined_file" "$_hash1_file" "$_hash2_file"

  # Generate random salt (32 bytes BINARY)
  openssl rand $_salt_bytes > "$_salt_file"

  # Write password (no newline!)
  printf '%s' "${_pass}" > "$_pass_file"

  # Binary concatenation: salt + password
  cat "$_salt_file" "$_pass_file" > "$_combined_file"

  # Double SHA256
  openssl dgst -sha256 -binary "$_combined_file" > "$_hash1_file"
  openssl dgst -sha256 -binary "$_hash1_file" > "$_hash2_file"

  # Base64 encode
  _hash_b64="$($_base64_cmd < "$_hash2_file" | tr -d '\n\r')"
  _salt_b64="$($_base64_cmd < "$_salt_file" | tr -d '\n\r')"

  # Cleanup (overwrite before delete)
  dd if=/dev/zero of="$_salt_file" bs=1 count="$(wc -c < "$_salt_file")" 2>/dev/null || true
  dd if=/dev/zero of="$_pass_file" bs=1 count="$(wc -c < "$_pass_file")" 2>/dev/null || true
  dd if=/dev/zero of="$_combined_file" bs=1 count="$(wc -c < "$_combined_file")" 2>/dev/null || true
  dd if=/dev/zero of="$_hash1_file" bs=1 count="$(wc -c < "$_hash1_file")" 2>/dev/null || true
  dd if=/dev/zero of="$_hash2_file" bs=1 count="$(wc -c < "$_hash2_file")" 2>/dev/null || true
  rm -f "$_salt_file" "$_pass_file" "$_combined_file" "$_hash1_file" "$_hash2_file"

  # Output: "HASH SALT"
  printf '%s %s' "${_hash_b64}" "${_salt_b64}"
}

#Helper: generate secure password ---
generate_secure_password() {
  openssl rand -hex 16
}

#Load or generate defaults ---
load_or_generate() {
  var="$1"
  def="$2"

  # Validate variable name (only alphanumeric and underscore)
  case "$var" in
    *[!A-Za-z0-9_]*)
      echo "ERROR: Invalid variable name: $var" >&2
      exit 1
      ;;
  esac

  # Safely get variable value
  # shellcheck disable=SC1083,SC2086
  val="$(eval echo \"\${$var:-}\")"

  # Generate secure password if empty or contains CHANGE_ME
  if [ -z "$val" ] || echo "$val" | grep -qi "CHANGE_ME"; then
    val="$(generate_secure_password)"
    echo "→ Generated secure password for $var"
  fi

  eval "$var=\$val"
}

load_or_generate SOLR_ADMIN_PASSWORD ""
load_or_generate SOLR_SUPPORT_PASSWORD ""
load_or_generate SOLR_MOODLE_PASSWORD ""

#credentials
ADMIN_USER="${SOLR_ADMIN_USER:-admin}"
SUPPORT_USER="${SOLR_SUPPORT_USER:-support}"
MOODLE_USER="${SOLR_MOODLE_USER:-moodle}"

# Validate usernames (alphanumeric and underscore only)
for _user_var in ADMIN_USER SUPPORT_USER MOODLE_USER; do
  _user_val="$(eval echo \"\$$_user_var\")"
  case "$_user_val" in
    *[!A-Za-z0-9_]*)
      echo "ERROR: Invalid username in $_user_var: '$_user_val'. Only alphanumeric and underscore allowed." >&2
      exit 4
      ;;
  esac
done

# Keep plain passwords for Prometheus and other services that need plain auth
ADMIN_PASS_PLAIN="${SOLR_ADMIN_PASSWORD}"
SUPPORT_PASS_PLAIN="${SOLR_SUPPORT_PASSWORD}"
MOODLE_PASS_PLAIN="${SOLR_MOODLE_PASSWORD}"

# -------------------------------------------------------------------
# Detect password changes and regenerate security.json if needed
# -------------------------------------------------------------------
PASS_HASH_FILE="${DATA_DIR}/.password_checksum"

# Compute checksum of current passwords
CURRENT_PASS_HASH="$(printf '%s\n%s\n%s\n%s\n%s\n%s' \
  "${ADMIN_USER}" "${ADMIN_PASS_PLAIN}" \
  "${SUPPORT_USER}" "${SUPPORT_PASS_PLAIN}" \
  "${MOODLE_USER}" "${MOODLE_PASS_PLAIN}" \
  | openssl dgst -sha256 | awk '{print $2}')"

# Check if passwords have changed
REGENERATE_SECURITY=0
if [ ! -f "${DATA_DIR}/security.json" ]; then
  echo "→ Creating new security.json (first run)"
  REGENERATE_SECURITY=1
elif [ ! -f "$PASS_HASH_FILE" ]; then
  echo "→ Password checksum missing, regenerating security.json"
  REGENERATE_SECURITY=1
else
  STORED_PASS_HASH="$(cat "$PASS_HASH_FILE" 2>/dev/null || echo '')"
  if [ "$CURRENT_PASS_HASH" != "$STORED_PASS_HASH" ]; then
    echo "→ Passwords changed, regenerating security.json"
    REGENERATE_SECURITY=1
  else
    echo "✓ Passwords unchanged, preserving security.json"
  fi
fi

if [ "$REGENERATE_SECURITY" = "1" ]; then
  mkdir -p "${DATA_DIR}"

  # Hash plain passwords once for security.json
  ADMIN_CRED="$(hash_solr_basic_auth "${ADMIN_PASS_PLAIN}")"
  SUPPORT_CRED="$(hash_solr_basic_auth "${SUPPORT_PASS_PLAIN}")"
  MOODLE_CRED="$(hash_solr_basic_auth "${MOODLE_PASS_PLAIN}")"

  # Template ersetzen, falls vorhanden (aus /init, nicht /config)
  if [ -f "/init/security.json.template" ]; then
    if ! sed -e "s#__ADMIN_USER__#${ADMIN_USER}#g" \
        -e "s#__SUPPORT_USER__#${SUPPORT_USER}#g" \
        -e "s#__MOODLE_USER__#${MOODLE_USER}#g" \
        -e "s#__ADMIN_HASH__#${ADMIN_CRED}#g" \
        -e "s#__SUPPORT_HASH__#${SUPPORT_CRED}#g" \
        -e "s#__MOODLE_HASH__#${MOODLE_CRED}#g" \
        "/init/security.json.template" > "${DATA_DIR}/security.json"; then
      echo "ERROR: Failed to generate security.json from template" >&2
      exit 1
    fi
  else
    echo "No security.json.template found - generating minimal inline file"
    cat > "${DATA_DIR}/security.json" <<EOF
{
  "authentication": {
    "blockUnknown": true,
    "class": "solr.BasicAuthPlugin",
    "realm": "Eledia",
    "credentials": {
      "${ADMIN_USER}": "${ADMIN_CRED}",
      "${SUPPORT_USER}": "${SUPPORT_CRED}",
      "${MOODLE_USER}": "${MOODLE_CRED}"
    }
  },
  "authorization": {
    "class": "solr.RuleBasedAuthorizationPlugin",
    "user-role": {
      "${ADMIN_USER}": ["admin"],
      "${SUPPORT_USER}": ["support"],
      "${MOODLE_USER}": ["moodle"]
    },
    "permissions": [
      { "name": "all", "role": "admin" },
      { "name": "read", "role": ["support", "moodle"] },
      { "name": "update", "role": "moodle" }
    ]
  }
}
EOF
  fi
  chmod 600 "${DATA_DIR}/security.json"

  # Save password checksum for future comparisons (secure permissions!)
  echo "$CURRENT_PASS_HASH" > "$PASS_HASH_FILE"
  chmod 600 "$PASS_HASH_FILE"
  chown 8983:8983 "$PASS_HASH_FILE" 2>/dev/null || true

  echo "✓ security.json created/updated"
fi

# -------------------------------------------------------------------
# Dynamic Core Management
# -------------------------------------------------------------------
CORE_STATE_FILE="${DATA_DIR}/.core_state"
CURRENT_CORES="${SOLR_CORE_NAME}"

# Handle multi-core setup
if [ -n "${SOLR_CORES:-}" ]; then
  CURRENT_CORES="${SOLR_CORES}"
fi

# Read previous core state
if [ -f "$CORE_STATE_FILE" ]; then
  PREVIOUS_CORES="$(cat "$CORE_STATE_FILE" 2>/dev/null || echo '')"
else
  PREVIOUS_CORES=""
fi

# Function: create core
create_core() {
  local core_name="$1"
  local core_dir="${DATA_DIR}/${core_name}"
  local core_conf="${core_dir}/conf"

  if [ -f "${core_dir}/core.properties" ]; then
    echo "→ Core '${core_name}' already exists"
    return 0
  fi

  echo "→ Creating core '${core_name}'"
  mkdir -p "${core_conf}" || {
    echo "ERROR: Failed to create core directory for ${core_name}" >&2
    return 1
  }

  if ! cp -a "${CONF_SRC}/." "${core_conf}/"; then
    echo "ERROR: Failed to copy config files for ${core_name}" >&2
    return 1
  fi

  cat > "${core_dir}/core.properties" <<EOF
name=${core_name}
EOF

  chown -R 8983:8983 "${core_dir}" 2>/dev/null || true
  echo "✓ Core created: ${core_name}"
}

# Function: rename core
rename_core() {
  local old_name="$1"
  local new_name="$2"
  local old_dir="${DATA_DIR}/${old_name}"
  local new_dir="${DATA_DIR}/${new_name}"

  if [ ! -d "$old_dir" ]; then
    echo "→ Old core '${old_name}' not found, creating new core '${new_name}'"
    create_core "$new_name"
    return 0
  fi

  if [ -d "$new_dir" ]; then
    echo "→ Target core '${new_name}' already exists, skipping rename"
    return 0
  fi

  echo "→ Renaming core '${old_name}' to '${new_name}'"
  mv "$old_dir" "$new_dir"

  # Update core.properties
  sed -i "s/^name=.*/name=${new_name}/" "${new_dir}/core.properties"

  chown -R 8983:8983 "${new_dir}" 2>/dev/null || true
  echo "✓ Core renamed: ${old_name} → ${new_name}"
}

# Function: delete core
delete_core() {
  local core_name="$1"
  local core_dir="${DATA_DIR}/${core_name}"

  if [ ! -d "$core_dir" ]; then
    echo "→ Core '${core_name}' does not exist"
    return 0
  fi

  echo "→ Deleting core '${core_name}'"

  # Create backup
  local backup_dir="${DATA_DIR}/backup/deleted_cores"
  mkdir -p "$backup_dir"
  local timestamp
  timestamp="$(date +%Y%m%d_%H%M%S)"
  mv "$core_dir" "${backup_dir}/${core_name}_${timestamp}"

  echo "✓ Core deleted (backed up to backup/deleted_cores)"
}

# Parse cores (comma-separated)
IFS=',' read -ra CURRENT_CORE_ARRAY <<< "$CURRENT_CORES"
IFS=',' read -ra PREVIOUS_CORE_ARRAY <<< "$PREVIOUS_CORES"

# Detect changes
echo "→ Current cores: ${CURRENT_CORES}"
echo "→ Previous cores: ${PREVIOUS_CORES}"

# Create new cores
for core in "${CURRENT_CORE_ARRAY[@]}"; do
  core="$(echo "$core" | tr -d ' ')"  # Trim whitespace
  if [ -z "$core" ]; then continue; fi

  # Check if core is new
  if ! echo ",$PREVIOUS_CORES," | grep -q ",${core},"; then
    create_core "$core"
  else
    echo "→ Core '${core}' unchanged"
  fi
done

# Delete removed cores
if [ -n "$PREVIOUS_CORES" ]; then
  for core in "${PREVIOUS_CORE_ARRAY[@]}"; do
    core="$(echo "$core" | tr -d ' ')"  # Trim whitespace
    if [ -z "$core" ]; then continue; fi

    # Check if core was removed
    if ! echo ",$CURRENT_CORES," | grep -q ",${core},"; then
      delete_core "$core"
    fi
  done
fi

# Save current state
echo "$CURRENT_CORES" > "$CORE_STATE_FILE"
chmod 600 "$CORE_STATE_FILE"
chown 8983:8983 "$CORE_STATE_FILE" 2>/dev/null || true

# -------------------------------------------------------------------
# Generate Prometheus config into mounted volume
# -------------------------------------------------------------------
# NOTE: Prometheus requires plaintext credentials in config file.
# This is a Prometheus limitation. File is protected with 600 permissions.
# Alternative: Use Prometheus with external secret management or OAuth proxy.
mkdir -p "${PROM_CFG_DIR}" 2>/dev/null || true
chmod 755 "${PROM_CFG_DIR}" 2>/dev/null || true
if touch "${PROM_CFG_FILE}" 2>/dev/null; then
  cat > "${PROM_CFG_FILE}" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: solr
    scrape_interval: 30s
    scrape_timeout: 10s
    metrics_path: /solr/admin/metrics
    params:
      wt: ["prometheus"]
    basic_auth:
      username: "${SUPPORT_USER}"
      password: "${SUPPORT_PASS_PLAIN}"
    static_configs:
      - targets: ["solr:8983"]
EOF
  chmod 600 "${PROM_CFG_FILE}" 2>/dev/null || true
  chown 65534:65534 "${PROM_CFG_FILE}" 2>/dev/null || true
  chown 65534:65534 "${PROM_CFG_DIR}" 2>/dev/null || true
  echo "✓ Prometheus config created"
fi
#Fix file permissions
echo "→ Fixing permissions..."
chown -R 8983:8983 "${DATA_DIR}" || true
chmod -R 750 "${DATA_DIR}" || true
find "${DATA_DIR}" -type f -exec chmod 640 {} \; 2>/dev/null || true

# Secure sensitive files AFTER recursive chmod (600 = owner read/write only)
# These must be set explicitly to override the recursive permissions above
if [ -f "${DATA_DIR}/security.json" ]; then
    chmod 600 "${DATA_DIR}/security.json"
    echo "  → security.json: 600"
fi
if [ -f "${DATA_DIR}/.password_checksum" ]; then
    chmod 600 "${DATA_DIR}/.password_checksum"
    echo "  → .password_checksum: 600"
fi
if [ -f "${CORE_STATE_FILE}" ]; then
    chmod 600 "${CORE_STATE_FILE}"
    echo "  → .core_state: 600"
fi
if [ -f "${ENV_FILE_PATH}" ]; then
    chmod 600 "${ENV_FILE_PATH}" 2>/dev/null || true
    echo "  → host .env: 600"
fi

# Ensure all filesystem changes are written to disk before exiting
sync
sleep 1
