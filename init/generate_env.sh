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
apk add --no-cache openssl >/dev/null

# Generate random passwords
ADMIN_PASS="$(rand)"
SUPPORT_PASS="$(rand)"
MOODLE_PASS="$(rand)"

# Write .env file
cat > "${ENV_FILE}" <<EOF
# =========================================
# Solr for Moodle - Environment
# =========================================
# Instance name
INSTANCE_NAME=${INSTANCE_NAME:-solr}

# Solr
SOLR_VERSION=9.10.1
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

# Docker resource limits
SOLR_CPU_LIMIT=2
SOLR_MEMORY_LIMIT=4G
SOLR_CPU_RESERVATION=0.5
SOLR_MEMORY_RESERVATION=2G

# =========================================
# Info / Documentation (not used in code)
# =========================================
# CUSTOMER_NAME=<customer name for admin reference>
# NOTES=<additional notes>
EOF

# .env: root-owned, docker-group-readable (640)
# DOCKER_GID can be passed as env var to avoid mounting the Docker socket.
# Fallback: detect from /var/run/docker.sock (requires socket mount).
if [ -n "${DOCKER_GID:-}" ] && [ "${DOCKER_GID}" != "0" ]; then
  # GID provided via environment — no socket needed
  chown "root:${DOCKER_GID}" "${ENV_FILE}"
  chmod 640 "${ENV_FILE}"
elif [ -S /var/run/docker.sock ]; then
  DOCKER_GID=$(stat -c %g /var/run/docker.sock 2>/dev/null || echo "0")
  if [ "$DOCKER_GID" != "0" ]; then
    chown "root:${DOCKER_GID}" "${ENV_FILE}"
    chmod 640 "${ENV_FILE}"
  else
    chmod 600 "${ENV_FILE}"
  fi
else
  # Fallback: only root (rootless Docker or no socket available)
  chmod 600 "${ENV_FILE}"
fi

echo "Created ${ENV_FILE}"
echo "Owner (uid:gid): $(stat -c '%u:%g' "${ENV_FILE}" 2>/dev/null || echo 'n/a')"
echo "Permissions: $(stat -c '%A' "${ENV_FILE}" 2>/dev/null || echo 'n/a')"
