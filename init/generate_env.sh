#!/bin/sh
# =====================================================
# /init/generate_env.sh
#   Generate .env file in the root directory 
#   Works safely under SELinux
# =====================================================

set -eu

# Absolute path inside container (host-mounted root directory)
TARGET_DIR="/app"
ENV_FILE="${TARGET_DIR}/.env"

# Helper: generate random 32-char secret (alphanumeric, high entropy)
rand() { openssl rand -base64 36 | tr -d '/+=' | head -c 32; }

# Ensure directory exists
mkdir -p "${TARGET_DIR}"

# Skip if already exists
if [ -f "${ENV_FILE}" ]; then
  echo "${ENV_FILE} already exists - skipping generation."
  echo "   Owner (uid:gid): $(stat -c '%u:%g' "${ENV_FILE}" 2>/dev/null || echo 'n/a')"
  echo "   Permissions:      $(stat -c '%A' "${ENV_FILE}" 2>/dev/null || echo 'n/a')"
  exit 0
fi

# Dependencies
apk add --no-cache openssl >/dev/null 2>&1

# Generate random passwords
ADMIN_PASS="$(rand)"
SUPPORT_PASS="$(rand)"
MOODLE_PASS="$(rand)"
GRAFANA_PASS="$(rand)"

# Write .env file
cat > "${ENV_FILE}" <<EOF
# =========================================
# Solr for Moodle - Environment
# =========================================
# Instance name
INSTANCE_NAME=${INSTANCE_NAME:-solr}

# Solr
SOLR_VERSION=9.10.0
SOLR_PORT=8983
SOLR_BIND=127.0.0.1
SOLR_CORE_NAME=${SOLR_CORE_NAME:-moodle_core}
SOLR_CORES=
SOLR_HEAP=2g
SOLR_LOG_LEVEL=INFO

# Network
SOLR_NETWORK_NAME=solr_network

# Users (used for security.json generation)
SOLR_ADMIN_USER=admin
SOLR_ADMIN_PASSWORD=${ADMIN_PASS}
SOLR_SUPPORT_USER=support
SOLR_SUPPORT_PASSWORD=${SUPPORT_PASS}
SOLR_MOODLE_USER=moodle
SOLR_MOODLE_PASSWORD=${MOODLE_PASS}

# Monitoring (v1.5)
MONITORING_BIND_IP=127.0.0.1
SOLR_METRICS_PORT=9854
PROMETHEUS_PORT=9090
PROMETHEUS_BIND=127.0.0.1
GRAFANA_PORT=3000
GRAFANA_BIND=127.0.0.1
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=${GRAFANA_PASS}

# =========================================
# Info / Documentation (not used in code)
# =========================================
# CUSTOMER_NAME=<customer name for admin reference>
# NOTES=<additional notes>
EOF

# Set permissions for host user readability
# Use 644 for CI/CD compatibility (read for all, write for owner only)
chmod 644 "${ENV_FILE}"

echo "Created ${ENV_FILE}"
echo "Owner (uid:gid): $(stat -c '%u:%g' "${ENV_FILE}" 2>/dev/null || echo 'n/a')"
echo "Permissions: $(stat -c '%A' "${ENV_FILE}" 2>/dev/null || echo 'n/a')"
