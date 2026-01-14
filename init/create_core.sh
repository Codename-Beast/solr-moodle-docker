#!/bin/sh
# /init/create_core.sh
# Purpose: Create a standalone Solr core directory with Moodle schema BEFORE Solr starts.
# Notes:
# - Uses config files deployed by powerinit.sh into /var/solr/data/configs + /var/solr/data/lang
# - Creates: /var/solr/data/<CORE>/core.properties + conf/*

set -eu

CORE_NAME="${SOLR_CORE_NAME:-moodle_core}"
CORE_DIR="/var/solr/data/${CORE_NAME}"
CONF_DIR="${CORE_DIR}/conf"

echo "========================================="
echo "Create Core (standalone) - ${CORE_NAME}"
echo "========================================="

# ------------------------------------------------------------
# Function: backup_existing_core
# Purpose : Moves an existing core directory to backup timestamp folder
# ------------------------------------------------------------
backup_existing_core() {
  ts="$(date +%Y%m%d_%H%M%S)"
  mkdir -p /var/solr/data/backup
  mv "${CORE_DIR}" "/var/solr/data/backup/${CORE_NAME}_${ts}" 2>/dev/null || true
}

# If core exists but is empty/broken, you can force recreate by deleting it manually.
if [ -d "${CORE_DIR}" ] && [ -f "${CORE_DIR}/core.properties" ]; then
  echo "Core already exists (${CORE_DIR}) - skipping create."
  exit 0
fi

# Validate required config files exist (from your repo /config via powerinit)
if [ ! -f "/var/solr/data/configs/managed-schema" ] || [ ! -f "/var/solr/data/configs/solrconfig.xml" ]; then
  echo "ERROR: Missing configs in volume:"
  echo "  - /var/solr/data/configs/managed-schema"
  echo "  - /var/solr/data/configs/solrconfig.xml"
  echo "Gibts den ./config im Repo ? wenn nicht pech ;)"
  exit 2
fi

# If a half-created directory exists, back it up for safety
if [ -d "${CORE_DIR}" ]; then
  echo "Core dir exists but missing core.properties - backing up."
  backup_existing_core
fi

mkdir -p "${CONF_DIR}"

# Copy configs
cp -f /var/solr/data/configs/managed-schema "${CONF_DIR}/managed-schema"
cp -f /var/solr/data/configs/solrconfig.xml "${CONF_DIR}/solrconfig.xml"

# Optional language files
if [ -d "/var/solr/data/lang" ] && [ "$(ls -1 /var/solr/data/lang 2>/dev/null | wc -l)" -gt 0 ]; then
  mkdir -p "${CONF_DIR}/lang"
  cp -f /var/solr/data/lang/* "${CONF_DIR}/lang/" 2>/dev/null || true
fi

# Create core.properties
cat > "${CORE_DIR}/core.properties" <<EOF
name=${CORE_NAME}
config=solrconfig.xml
schema=managed-schema
dataDir=data
EOF

# Permissions (Solr runs as 8983)
chown -R 8983:8983 "${CORE_DIR}"
chmod 644 "${CORE_DIR}/core.properties" "${CONF_DIR}/solrconfig.xml" "${CONF_DIR}/managed-schema" 2>/dev/null || true

echo "Core prepared in volume: ${CORE_DIR}"
echo "Solr will auto-discover cores via core.properties on startup."