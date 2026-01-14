#!/bin/sh
# /init/powerinit.sh
# Purpose:
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

# --- Optional: load external .env if provided ---
if [ -n "${ENV_FILE_PATH:-}" ] && [ -f "$ENV_FILE_PATH" ]; then
  echo "→ Loading environment from $ENV_FILE_PATH"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE_PATH"
  set +a
else
  echo "No external .env found at $ENV_FILE_PATH - using defaults"
fi

# --- Helper: detect pre-hashed password (32+ hex chars or contains space salt) ---
is_hashed() {
  echo "$1" | grep -Eq '^[0-9a-f]{32,}$|[A-Za-z0-9+/=]+\s+[A-Za-z0-9+/=]+'
}

# --- Helper: create Solr-compatible BasicAuth hash ---
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

  # Cleanup
  rm -f "$_salt_file" "$_pass_file" "$_combined_file" "$_hash1_file" "$_hash2_file"

  # Output: "HASH SALT"
  printf '%s %s' "${_hash_b64}" "${_salt_b64}"
}

# --- Load or generate defaults ---
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
  val="$(eval echo \"\${$var:-}\")"
  if [ -z "$val" ]; then
    val="$def"
    echo "→ generated default for $var"
  fi
  eval "$var=\$val"
}

load_or_generate SOLR_ADMIN_PASSWORD "eledia_default"
load_or_generate SOLR_SUPPORT_PASSWORD "eledia_default"
load_or_generate SOLR_MOODLE_PASSWORD "eledia_default"

# --- Prepare credentials ---
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
# [2] Detect password changes and regenerate security.json if needed
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
    echo "Passwords unchanged, preserving security.json"
  fi
fi

if [ "$REGENERATE_SECURITY" = "1" ]; then
  mkdir -p "${DATA_DIR}"

  # Hash plain passwords once for security.json
  ADMIN_CRED="$(hash_solr_basic_auth "${ADMIN_PASS_PLAIN}")"
  SUPPORT_CRED="$(hash_solr_basic_auth "${SUPPORT_PASS_PLAIN}")"
  MOODLE_CRED="$(hash_solr_basic_auth "${MOODLE_PASS_PLAIN}")"

  # Template ersetzen, falls vorhanden
  if [ -f "${CONF_SRC}/security.json.template" ]; then
    if ! sed -e "s#__ADMIN_USER__#${ADMIN_USER}#g" \
        -e "s#__SUPPORT_USER__#${SUPPORT_USER}#g" \
        -e "s#__MOODLE_USER__#${MOODLE_USER}#g" \
        -e "s#__ADMIN_HASH__#${ADMIN_CRED}#g" \
        -e "s#__SUPPORT_HASH__#${SUPPORT_CRED}#g" \
        -e "s#__MOODLE_HASH__#${MOODLE_CRED}#g" \
        "${CONF_SRC}/security.json.template" > "${DATA_DIR}/security.json"; then
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

  echo "security.json created/updated"
fi

# -------------------------------------------------------------------
# [3] Prepare Moodle core directory if missing
# -------------------------------------------------------------------
if [ ! -f "${CORE_DIR}/core.properties" ]; then
  echo "→ Creating Moodle core directory (${CORE_NAME})"
  mkdir -p "${CORE_CONF}" || {
    echo "ERROR: Failed to create core config directory" >&2
    exit 1
  }
  if ! cp -a "${CONF_SRC}/." "${CORE_CONF}/"; then
    echo "ERROR: Failed to copy config files to core directory" >&2
    exit 1
  fi
  cat > "${CORE_DIR}/core.properties" <<EOF
name=${CORE_NAME}
EOF
  echo "Core created"
else
  echo "Core already present - skip recreate"
fi

# -------------------------------------------------------------------
# [4] Generate Prometheus config into mounted volume
# -------------------------------------------------------------------
mkdir -p "${PROM_CFG_DIR}" || {
  echo "ERROR: Failed to create Prometheus config directory" >&2
  exit 1
}
cat > "${PROM_CFG_FILE}" <<EOF
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: solr
    metrics_path: /solr/admin/metrics
    params:
      wt: ["prometheus"]
    basic_auth:
      username: "${SUPPORT_USER}"
      password: "${SUPPORT_PASS_PLAIN}"
    static_configs:
      - targets: ["solr:8983"]
EOF

# -------------------------------------------------------------------
# [5] Fix file permissions
# -------------------------------------------------------------------
echo "→ Fixing permissions..."
chown -R 8983:8983 "${DATA_DIR}" || true
chmod -R 755 "${DATA_DIR}" || true
chown -R 65534:65534 "${PROM_CFG_DIR}" || true

# Secure sensitive files AFTER recursive chmod (600 = owner read/write only)
# These must be set explicitly to override the recursive 755 above
if [ -f "${DATA_DIR}/security.json" ]; then
    chmod 600 "${DATA_DIR}/security.json"
    echo "  → security.json: 600"
fi
if [ -f "${DATA_DIR}/.password_checksum" ]; then
    chmod 600 "${DATA_DIR}/.password_checksum"
    echo "  → .password_checksum: 600"
fi
echo "Permissions set"

# Ensure all filesystem changes are written to disk before exiting
echo "Syncing filesystem..."
sync
sleep 1
echo "Filesystem synced"

echo "Initialization completed successfully."