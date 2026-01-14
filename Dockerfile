FROM alpine:3.20
# =========================================
# Solr Init Container
# Developer: BSC Bernd Schreistetter
# Company: Eledia.de
# Version: v2.1
# =========================================
RUN apk add --no-cache \
    openssl \
    coreutils \
    bash \
    curl \
    ca-certificates

# Create working directories
RUN mkdir -p /config /workspace /var/solr/data /prometheus-config

# Copy configuration files into image
COPY config/ /config/

# Set working directory
WORKDIR /

# Embedded initialization script
COPY <<'EOF' /entrypoint.sh
#!/bin/bash
set -eu

DATA_DIR="/var/solr/data"
CORE_NAME="${SOLR_CORE_NAME:-moodle_core}"
CONF_SRC="/config"
CORE_DIR="${DATA_DIR}/${CORE_NAME}"
CORE_CONF="${CORE_DIR}/conf"
PROM_CFG_DIR="/prometheus-config"
PROM_CFG_FILE="${PROM_CFG_DIR}/prometheus.yml"
PASS_HASH_FILE="${DATA_DIR}/.password_checksum"

# Validate core name
case "$CORE_NAME" in
  *[!A-Za-z0-9_-]*)
    echo "ERROR: Invalid CORE_NAME '$CORE_NAME'" >&2
    exit 4
    ;;
  */*)
    echo "ERROR: CORE_NAME cannot contain path separators" >&2
    exit 4
    ;;
esac

# Validate config exists
if [ ! -d "$CONF_SRC" ]; then
  echo "ERROR: Config directory $CONF_SRC not found" >&2
  exit 2
fi

# Load external .env if provided
if [ -n "${ENV_FILE_PATH:-}" ] && [ -f "$ENV_FILE_PATH" ]; then
  echo "→ Loading environment from $ENV_FILE_PATH"
  set -a
  . "$ENV_FILE_PATH"
  set +a
else
  echo "⚠ No external .env found — using defaults"
fi

# Load or generate defaults
for var in SOLR_ADMIN_PASSWORD SOLR_SUPPORT_PASSWORD SOLR_MOODLE_PASSWORD; do
  val="$(eval echo \${$var:-})"
  if [ -z "$val" ]; then
    eval "$var='eledia_default'"
    echo "→ Using default for $var"
  fi
done

# Prepare credentials
ADMIN_USER="${SOLR_ADMIN_USER:-admin}"
SUPPORT_USER="${SOLR_SUPPORT_USER:-support}"
MOODLE_USER="${SOLR_MOODLE_USER:-moodle}"

# Validate usernames
for _user_var in ADMIN_USER SUPPORT_USER MOODLE_USER; do
  _user_val="$(eval echo \"\$$_user_var\")"
  case "$_user_val" in
    *[!A-Za-z0-9_]*)
      echo "ERROR: Invalid username in $_user_var" >&2
      exit 4
      ;;
  esac
done

# Plain passwords
ADMIN_PASS_PLAIN="${SOLR_ADMIN_PASSWORD}"
SUPPORT_PASS_PLAIN="${SOLR_SUPPORT_PASSWORD}"
MOODLE_PASS_PLAIN="${SOLR_MOODLE_PASSWORD}"

# Hash function: DOUBLE SHA256
hash_password() {
  local password="$1"
  local salt_file="$(mktemp)"
  local pass_file="$(mktemp)"
  local combined_file="$(mktemp)"
  local hash1_file="$(mktemp)"
  local hash2_file="$(mktemp)"

  chmod 600 "$salt_file" "$pass_file" "$combined_file" "$hash1_file" "$hash2_file"

  openssl rand 32 > "$salt_file"
  printf '%s' "$password" > "$pass_file"
  cat "$salt_file" "$pass_file" > "$combined_file"

  openssl dgst -sha256 -binary "$combined_file" > "$hash1_file"
  openssl dgst -sha256 -binary "$hash1_file" > "$hash2_file"

  if base64 --help 2>&1 | grep -q 'wrap'; then
    local hash_b64="$(base64 -w 0 < "$hash2_file")"
    local salt_b64="$(base64 -w 0 < "$salt_file")"
  else
    local hash_b64="$(base64 < "$hash2_file" | tr -d '\n')"
    local salt_b64="$(base64 < "$salt_file" | tr -d '\n')"
  fi

  dd if=/dev/zero of="$salt_file" bs=1 count=$(wc -c < "$salt_file") 2>/dev/null || true
  dd if=/dev/zero of="$pass_file" bs=1 count=$(wc -c < "$pass_file") 2>/dev/null || true
  dd if=/dev/zero of="$combined_file" bs=1 count=$(wc -c < "$combined_file") 2>/dev/null || true
  dd if=/dev/zero of="$hash1_file" bs=1 count=$(wc -c < "$hash1_file") 2>/dev/null || true
  dd if=/dev/zero of="$hash2_file" bs=1 count=$(wc -c < "$hash2_file") 2>/dev/null || true
  rm -f "$salt_file" "$pass_file" "$combined_file" "$hash1_file" "$hash2_file"

  echo "${hash_b64} ${salt_b64}"
}

# Password change detection
CURRENT_PASS_HASH="$(printf '%s\n%s\n%s\n%s\n%s\n%s' \
  "${ADMIN_USER}" "${ADMIN_PASS_PLAIN}" \
  "${SUPPORT_USER}" "${SUPPORT_PASS_PLAIN}" \
  "${MOODLE_USER}" "${MOODLE_PASS_PLAIN}" \
  | openssl dgst -sha256 | awk '{print $2}')"

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

  ADMIN_CRED="$(hash_password "${ADMIN_PASS_PLAIN}")"
  SUPPORT_CRED="$(hash_password "${SUPPORT_PASS_PLAIN}")"
  MOODLE_CRED="$(hash_password "${MOODLE_PASS_PLAIN}")"

  if [ -f "${CONF_SRC}/security.json.template" ]; then
    sed -e "s#__ADMIN_USER__#${ADMIN_USER}#g" \
        -e "s#__SUPPORT_USER__#${SUPPORT_USER}#g" \
        -e "s#__MOODLE_USER__#${MOODLE_USER}#g" \
        -e "s#__ADMIN_HASH__#${ADMIN_CRED}#g" \
        -e "s#__SUPPORT_HASH__#${SUPPORT_CRED}#g" \
        -e "s#__MOODLE_HASH__#${MOODLE_CRED}#g" \
        "${CONF_SRC}/security.json.template" > "${DATA_DIR}/security.json"
  else
    cat > "${DATA_DIR}/security.json" <<EOJ
{
  "authentication": {
    "blockUnknown": true,
    "class": "solr.BasicAuthPlugin",
    "realm": "Solr Moodle Search - by Eledia.de",
    "credentials": {
      "${ADMIN_USER}": "${ADMIN_CRED}",
      "${SUPPORT_USER}": "${SUPPORT_CRED}",
      "${MOODLE_USER}": "${MOODLE_CRED}"
    },
    "forwardCredentials": false
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
      { "name": "config-read", "role": ["admin", "support"] },
      { "name": "health", "role": ["admin", "support"] },
      { "name": "read", "role": ["admin", "support", "moodle"] },
      { "name": "update", "role": ["admin", "moodle"] }
    ]
  }
}
EOJ
  fi

  chmod 644 "${DATA_DIR}/security.json"
  echo "$CURRENT_PASS_HASH" > "$PASS_HASH_FILE"
  chmod 644 "$PASS_HASH_FILE"
  echo "✓ security.json created/updated"
fi

# Create core
if [ ! -f "${CORE_DIR}/core.properties" ]; then
  echo "→ Creating Moodle core directory (${CORE_NAME})"
  mkdir -p "${CORE_CONF}"
  cp -a "${CONF_SRC}/." "${CORE_CONF}/"
  cat > "${CORE_DIR}/core.properties" <<EOC
name=${CORE_NAME}
EOC
  echo "✓ Core created: ${CORE_NAME}"
else
  echo "✓ Core already exists — skipping creation"
fi

# Generate Prometheus config
mkdir -p "${PROM_CFG_DIR}"
cat > "${PROM_CFG_FILE}" <<EOP
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: solr
    metrics_path: /solr/admin/metrics
    params:
      wt: ["prometheus"]
    basic_auth:
      username: "${ADMIN_USER}"
      password: "${ADMIN_PASS_PLAIN}"
    static_configs:
      - targets: ["solr:8983"]
EOP

echo "→ Setting correct permissions..."
chown -R 8983:8983 "${DATA_DIR}"
chmod -R 755 "${DATA_DIR}"
chown -R 65534:65534 "${PROM_CFG_DIR}"
chmod 600 "${DATA_DIR}/security.json"

# Sync filesystem before exiting (prevents race condition)
sync
sleep 1

echo "✓ Initialization completed successfully"
EOF

RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
