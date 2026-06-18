#!/bin/bash
# Copyright (c) 2026 eLeDia.de / Bernd Schreistetter (bsc)
# Version: v3.4.9

# =========================================
# Solr Multi-Tenant — Interactive Setup
# =========================================
# Idempotent: safe to re-run.
# First run: creates .env, tenants.env, /var/log/eledia/solr-<instance>.log, logrotate, starts Solr.
# Re-run: backs up .env (max 3 generations), updates passwords if requested.

set -euo pipefail

INSTANCE_NAME="${INSTANCE_NAME:-$(grep '^INSTANCE_NAME=' .env 2>/dev/null | cut -d= -f2 | tr -d ' ' || echo solr)}"
INSTANCE_NAME="${INSTANCE_NAME:-solr}"
LOG_ROOT="${LOG_ROOT:-/var/log/eledia}"
LOG_DIR="${LOG_DIR:-${LOG_ROOT}}"
LOG_FILE="${LOG_DIR}/solr-${INSTANCE_NAME}.log"

# _log: Write a timestamped message to stdout and $LOG_FILE.
# Args: $@ - message text
# Returns: nothing
_log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] %s\n' "$ts" "$* "
  printf '[%s] %s\n' "$ts" "$* " >> "$LOG_FILE" 2>/dev/null || true
}

# _die: Log an error message and exit with code 1.
# Args: $@ - error description
# Returns: exits with code 1
_die() {
  _log "ERROR: $*"
  exit 1
}

# _gen_password: Generate a random 32-character alphanumeric password.
# Args: none
# Returns: prints 32-character string to stdout
_gen_password() {
  openssl rand -base64 36 | tr -d '/+=' | head -c 32
}

# _env_get: Read a simple KEY=value from .env without evaluating shell code.
# Args: $1 - key name
# Returns: prints value (without surrounding whitespace) or nothing
_env_get() {
  local key="$1"
  grep -E "^${key}=" ".env" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d ' '
}

# _env_set: Set or append a simple KEY=value in .env.
# Args: $1 - key name, $2 - value
# Returns: nothing
_env_set() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  if grep -qE "^${key}=" ".env"; then
    awk -v key="$key" -v value="$value" 'BEGIN { FS=OFS="=" } $1 == key { $0 = key "=" value } { print }' ".env" > "$tmp"
  else
    cp ".env" "$tmp"
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi
  mv "$tmp" ".env"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if [ ! -f "docker-compose.yml" ]; then
  printf 'ERROR: Run setup.sh from the repo root directory.\n' >&2
  exit 1
fi

# Setup log file early (before _log works)
mkdir -p "$LOG_DIR" 2>/dev/null || {
  printf 'WARNING: Cannot create %s — continuing without file log\n' "$LOG_DIR" >&2
  LOG_FILE="/dev/null"
}
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"

_log "=== setup.sh started ==="

# ---------------------------------------------------------------------------
# Step 1: .env setup
# ---------------------------------------------------------------------------
_log "Step 1: Environment configuration"

FIRST_INSTALL=0
if [ ! -f ".env" ]; then
  _log "  First installation — no .env found"
  FIRST_INSTALL=1
  if [ ! -f ".env.example" ]; then
    _die ".env.example not found"
  fi
  cp ".env.example" ".env"
else
  _log "  Existing .env found"
  # Rotate backups: .env.backup.3 <- .env.backup.2 <- .env.backup.1 <- .env
  [ -f ".env.backup.2" ] && cp ".env.backup.2" ".env.backup.3"
  [ -f ".env.backup.1" ] && cp ".env.backup.1" ".env.backup.2"
  cp ".env" ".env.backup.1"
  _log "  Backup: .env -> .env.backup.1"
fi

# Read or generate admin password
printf '\n'
printf '=== Solr Admin Password ===\n'
if [ "$FIRST_INSTALL" = "1" ]; then
  printf '  Leave empty to auto-generate (recommended for first install).\n'
else
  printf '  Leave empty to keep the existing password from .env.\n'
fi
printf '  Admin password: '
read -r -s INPUT_ADMIN_PASS
printf '\n'

if [ -z "$INPUT_ADMIN_PASS" ]; then
  ADMIN_PASS="$(_env_get SOLR_ADMIN_PASSWORD)"
  if [ "$FIRST_INSTALL" = "1" ] || [ -z "$ADMIN_PASS" ] || echo "$ADMIN_PASS" | grep -qi "CHANGE_ME"; then
    ADMIN_PASS="$(_gen_password)"
    _log "  Admin password: auto-generated"
  else
    _log "  Admin password: preserved from existing .env"
  fi
else
  ADMIN_PASS="$INPUT_ADMIN_PASS"
  _log "  Admin password: set manually"
fi

printf '=== Solr Support Password ===\n'
if [ "$FIRST_INSTALL" = "1" ]; then
  printf '  Leave empty to auto-generate.\n'
else
  printf '  Leave empty to keep the existing password from .env.\n'
fi
printf '  Support password: '
read -r -s INPUT_SUPPORT_PASS
printf '\n'

if [ -z "$INPUT_SUPPORT_PASS" ]; then
  SUPPORT_PASS="$(_env_get SOLR_SUPPORT_PASSWORD)"
  if [ "$FIRST_INSTALL" = "1" ] || [ -z "$SUPPORT_PASS" ] || echo "$SUPPORT_PASS" | grep -qi "CHANGE_ME"; then
    SUPPORT_PASS="$(_gen_password)"
    _log "  Support password: auto-generated"
  else
    _log "  Support password: preserved from existing .env"
  fi
else
  SUPPORT_PASS="$INPUT_SUPPORT_PASS"
  _log "  Support password: set manually"
fi

_env_set "SOLR_ADMIN_PASSWORD" "$ADMIN_PASS"
_env_set "SOLR_SUPPORT_PASSWORD" "$SUPPORT_PASS"
chmod 600 ".env"
if [ "$FIRST_INSTALL" = "1" ]; then
  _log "  .env created from .env.example with generated passwords"
else
  _log "  .env preserved; password fields updated only when requested"
fi

# ---------------------------------------------------------------------------
# Step 2: tenants.env
# ---------------------------------------------------------------------------
_log "Step 2: tenants.env"

if [ ! -f "tenants.env" ]; then
  touch "tenants.env"
  chown 8983:8983 "tenants.env" 2>/dev/null || true
  chmod 644 "tenants.env"
  _log "  Created empty tenants.env"
else
  chown 8983:8983 "tenants.env" 2>/dev/null || true
  chmod 644 "tenants.env"
  _log "  tenants.env already exists — preserving"
fi

# ---------------------------------------------------------------------------
# Step 3: Logging
# ---------------------------------------------------------------------------
_log "Step 3: Log directory"

mkdir -p "$LOG_DIR"
# Solr container UID 8983 can write native logs; docker group can read them on host.
chown 8983:docker "$LOG_DIR" 2>/dev/null || true
if [ "$(stat -c '%G' "$LOG_DIR" 2>/dev/null)" = "docker" ]; then
  chmod 750 "$LOG_DIR" 2>/dev/null || true
else
  chmod 755 "$LOG_DIR" 2>/dev/null || true
fi
_log "  Log directory: $LOG_DIR"

# Add the user who triggered the install to docker group so they can read logs without sudo
INSTALLING_USER="${SUDO_USER:-}"
if [ -n "$INSTALLING_USER" ] && [ "$INSTALLING_USER" != "root" ]; then
  if id "$INSTALLING_USER" >/dev/null 2>&1; then
    if usermod -aG docker "$INSTALLING_USER" 2>/dev/null; then
      _log "  Added '$INSTALLING_USER' to docker group (logout/login to apply)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Step 4: Logrotate
# ---------------------------------------------------------------------------
_log "Step 4: Logrotate"

LOGROTATE_FILE="/etc/logrotate.d/solr-eledia"
if [ -w "/etc/logrotate.d" ] || [ "$(id -u)" = "0" ]; then
  cat > "$LOGROTATE_FILE" <<EOF
${LOG_ROOT}/solr-*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
    create 640 root docker
}
EOF
  _log "  Logrotate config written to $LOGROTATE_FILE"
else
  _log "  WARNING: Cannot write to /etc/logrotate.d (run as root for logrotate setup)"
fi

# ---------------------------------------------------------------------------
# Step 5: Build init image
# ---------------------------------------------------------------------------
_log "Step 5: Building eLeDia-solr-init image"

if ! docker compose build eLeDia-solr-init 2>&1 | tee -a "$LOG_FILE"; then
  _die "docker compose build failed"
fi

# ---------------------------------------------------------------------------
# Step 6: Start stack
# ---------------------------------------------------------------------------
_log "Step 6: Starting Solr"

docker compose up -d 2>&1 | tee -a "$LOG_FILE"

# Wait for healthy (max 120s)
_log "  Waiting for Solr to become healthy (max 120s)..."
ELAPSED=0
HEALTHY=0
while [ $ELAPSED -lt 120 ]; do
  STATUS="$(docker compose ps --format json 2>/dev/null | grep -o '"Health":"[^"]*"' | head -1 | cut -d'"' -f4 || echo '')"
  if [ "$STATUS" = "healthy" ]; then
    HEALTHY=1
    break
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  printf '.'
done
printf '\n'

if [ "$HEALTHY" = "0" ]; then
  _log "ERROR: Solr did not become healthy within 120 seconds"
  _log "  Container logs:"
  docker compose logs --tail=50 2>&1 | tee -a "$LOG_FILE"

  if [ "$FIRST_INSTALL" = "0" ] && [ -f ".env.backup.1" ]; then
    _log "  Rolling back .env from backup"
    cp ".env.backup.1" ".env"
    docker compose down 2>&1 | tee -a "$LOG_FILE" || true
  else
    docker compose down 2>&1 | tee -a "$LOG_FILE" || true
  fi
  _die "Setup failed. Check $LOG_FILE for details."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
INSTANCE_NAME="$(grep '^INSTANCE_NAME=' .env | cut -d= -f2 | tr -d ' ')"
INSTANCE_NAME="${INSTANCE_NAME:-solr}"
SOLR_PORT="$(grep '^SOLR_PORT=' .env | cut -d= -f2 | tr -d ' ')"
SOLR_PORT="${SOLR_PORT:-8983}"

_log "=== Setup completed successfully ==="
_log "Collecting setup-time container logs into ${LOG_FILE}"
docker compose logs --no-color >> "$LOG_FILE" 2>&1 || true


printf '\n'
printf '╔══════════════════════════════════════════════════════════╗\n'
printf '║  Solr Multi-Tenant — Setup Complete                     ║\n'
printf '╠══════════════════════════════════════════════════════════╣\n'
printf '║  Instance:  %-44s║\n' "$INSTANCE_NAME"
printf '║  Solr URL:  http://127.0.0.1:%-27s║\n' "${SOLR_PORT}/solr"
printf '║  Logs:      %-44s║\n' "$LOG_DIR/"
printf '╠══════════════════════════════════════════════════════════╣\n'
printf '║  Next steps:                                             ║\n'
printf '║  1. Add tenants:                                         ║\n'
printf '║     docker exec %s-solr \\\n' "$INSTANCE_NAME"
printf '║       /opt/solr/scripts/solr-tenant.sh create <name> \\ ║\n'
printf '║       --cores <core1>[,<core2>]                          ║\n'
printf '║                                                          ║\n'
printf '║  2. List tenants:                                        ║\n'
printf '║     docker exec %s-solr \\\n' "$INSTANCE_NAME"
printf '║       /opt/solr/scripts/solr-tenant.sh list              ║\n'
printf '╚══════════════════════════════════════════════════════════╝\n'
printf '\n'
printf '  Admin credentials are in: .env\n'
printf '  Tenant credentials are in: tenants.env\n'
printf '\n'
