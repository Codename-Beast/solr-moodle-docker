#!/usr/bin/env bash
set -Eeuo pipefail

# One-way migration helper:
# Solr bare-metal (8/9/10/11) (/opt/solr + systemd) -> Docker runtime in this repository.
# No downgrade path.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"

INSTANCE_NAME="solr"
CUSTOMER_DOMAIN=""
LEGACY_SERVICE="solr"
LEGACY_SOLR_HOME=""
MIGRATION_ROOT="/var/backups/eledia-solr-migration"
TARGET_MODE="standalone"
DRY_RUN="false"

log() {
  local msg="$1"
  printf '[upgrade][instance:%s] %s\n' "$INSTANCE_NAME" "$msg"
}

logc() {
  local container="$1"; shift
  local msg="$*"
  printf '[upgrade][instance:%s][container:%s] %s\n' "$INSTANCE_NAME" "$container" "$msg"
}

err() {
  printf '[upgrade][instance:%s][ERROR] %s\n' "$INSTANCE_NAME" "$*" >&2
}

usage() {
  cat <<'EOF'
Usage:
  scripts/upgrade-docker.sh [options]

Options:
  --instance NAME            Docker instance name (default: solr)
  --customer-domain DOMAIN   Customer domain for default core name (core_<domain>)
  --legacy-service NAME      systemd service name of old Solr (default: solr)
  --legacy-solr-home PATH    Explicit old SOLR_HOME path (optional autodetect for 8/9/10/11)
  --migration-root PATH      Root for exported core backups
  --target-mode MODE         standalone|solrcloud (default: standalone)
  --dry-run                  Print actions only
  -h, --help                 Show help

Behavior:
  - Idempotent one-way migration (no rollback logic)
  - Exports legacy cores, stops/disables bare-metal service, starts Docker instance,
    imports exported cores into Docker volume, ensures runtime core naming fallback.
EOF
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }; }

sanitize_domain() {
  local in="$1"
  echo "$in" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//'
}

run() {
  # Executes the command as an argv array — no eval, no re-parsing of
  # expanded variables (paths with spaces, injection via $(...) etc.).
  if [ "$DRY_RUN" = "true" ]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# run_quiet: like run, but discards stdout (replaces inline '>/dev/null'
# that the old eval-based run() allowed inside command strings).
run_quiet() {
  if [ "$DRY_RUN" = "true" ]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@" >/dev/null
  fi
}

detect_legacy_solr_home() {
  if [ -n "$LEGACY_SOLR_HOME" ]; then
    return 0
  fi

  local candidates=(
    "/var/solr/data"
    "/opt/solr/server/solr"
    "/opt/solr/server/solr/mycores"
    "/opt/solr/data"
  )

  local c
  for c in "${candidates[@]}"; do
    if [ -d "$c" ] && find "$c" -maxdepth 3 -name core.properties -print -quit 2>/dev/null | grep -q .; then
      LEGACY_SOLR_HOME="$c"
      return 0
    fi
  done

  err "Could not detect legacy SOLR_HOME automatically. Use --legacy-solr-home"
  exit 1
}

load_env_file() {
  local env_file="${ROOT_DIR}/.env"
  [ -f "$env_file" ] || { err ".env missing in ${ROOT_DIR}"; exit 1; }
}

compose() {
  INSTANCE_NAME="$INSTANCE_NAME" SOLR_MODE="$TARGET_MODE" docker compose -f "$COMPOSE_FILE" "$@"
}

discover_instances() {
  docker ps --format '{{.Names}}|{{.Image}}|{{.Status}}' | awk -F'|' '$1 ~ /-solr$/ {print}' || true
}

ensure_instance_recognizable() {
  log "Active Solr Docker instances (recognizable):"
  discover_instances | sed 's/^/  - /' || true
}

stop_legacy_service() {
  if ! systemctl list-unit-files | grep -q "^${LEGACY_SERVICE}\.service"; then
    log "Legacy service ${LEGACY_SERVICE}.service not found; continue"
    return 0
  fi

  if systemctl is-active --quiet "${LEGACY_SERVICE}.service"; then
    log "Stopping legacy service ${LEGACY_SERVICE}.service"
    run systemctl stop "${LEGACY_SERVICE}.service"
  else
    log "Legacy service already stopped"
  fi

  if systemctl is-enabled --quiet "${LEGACY_SERVICE}.service"; then
    log "Disabling legacy service ${LEGACY_SERVICE}.service"
    run systemctl disable "${LEGACY_SERVICE}.service"
  fi
}

find_legacy_cores() {
  local home="$1"
  find "$home" -maxdepth 3 -type f -name core.properties -printf '%h\n' 2>/dev/null | sort -u
}

export_legacy_cores() {
  local home="$1" out="$2"
  mkdir -p "$out"

  local core_dirs=()
  while IFS= read -r d; do
    [ -n "$d" ] && core_dirs+=("$d")
  done < <(find_legacy_cores "$home")

  if [ "${#core_dirs[@]}" -eq 0 ]; then
    log "No legacy cores found in ${home}"
    return 0
  fi

  local d core
  for d in "${core_dirs[@]}"; do
    core="$(basename "$d")"
    log "Export core directory: ${core}"
    run rsync -a --delete "${d}/" "${out}/${core}/"
    if [ "$DRY_RUN" = "true" ]; then
      mkdir -p "${out}/${core}"
    fi
  done
}

ensure_default_core_name() {
  local core_name
  if [ -n "$CUSTOMER_DOMAIN" ]; then
    core_name="core_$(sanitize_domain "$CUSTOMER_DOMAIN")"
  else
    core_name="eLeDia_core"
  fi
  printf '%s' "$core_name"
}

import_cores_into_volume() {
  local export_dir="$1"
  local volume="solr_data_${INSTANCE_NAME}"
  local mountpoint

  shopt -s nullglob
  local entries=("${export_dir}"/*)
  shopt -u nullglob

  if [ "$DRY_RUN" = "true" ]; then
    if [ "${#entries[@]}" -eq 0 ]; then
      local fallback
      fallback="$(ensure_default_core_name)"
      log "[dry-run] Would create Moodle-optimized default core: ${fallback}"
    else
      local core_dir core
      for core_dir in "${entries[@]}"; do
        core="$(basename "$core_dir")"
        log "[dry-run] Would import core directory into Docker volume ${volume}: ${core}"
      done
    fi
    return 0
  fi

  mountpoint="$(docker volume inspect "$volume" --format '{{.Mountpoint}}' 2>/dev/null || true)"
  if [ -z "$mountpoint" ]; then
    err "Docker volume ${volume} not found"
    exit 1
  fi

  mkdir -p "$mountpoint"

  if [ "${#entries[@]}" -eq 0 ]; then
    local fallback
    fallback="$(ensure_default_core_name)"
    log "No exported cores. Creating Moodle-optimized default core: ${fallback}"
    local container="${INSTANCE_NAME}-solr"
    logc "$container" "create core ${fallback} with configSet=eLeDia-moodle-tenant"
    run_quiet docker exec "${container}" curl -sS -u "admin:${SOLR_ADMIN_PASSWORD:-admin}" "http://127.0.0.1:${SOLR_PORT:-8983}/solr/admin/cores?action=CREATE&name=${fallback}&configSet=eLeDia-moodle-tenant&wt=json"
    return 0
  fi

  local core_dir core
  for core_dir in "${entries[@]}"; do
    core="$(basename "$core_dir")"
    log "Import core directory into Docker volume: ${core}"
    run mkdir -p "${mountpoint}/${core}"
    run rsync -a --delete "${core_dir}/" "${mountpoint}/${core}/"
  done

  run chown -R 8983:8983 "${mountpoint}"
}

write_state_marker() {
  local state_file="$1"
  cat > "$state_file" <<EOF
instance=${INSTANCE_NAME}
legacy_service=${LEGACY_SERVICE}
legacy_solr_home=${LEGACY_SOLR_HOME}
target_mode=${TARGET_MODE}
completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

main() {
  need_cmd docker
  need_cmd rsync
  need_cmd systemctl

  local cli_instance_name="" cli_target_mode=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --instance) INSTANCE_NAME="$2"; cli_instance_name="$2"; shift 2 ;;
      --customer-domain) CUSTOMER_DOMAIN="$2"; shift 2 ;;
      --legacy-service) LEGACY_SERVICE="$2"; shift 2 ;;
      --legacy-solr-home) LEGACY_SOLR_HOME="$2"; shift 2 ;;
      --migration-root) MIGRATION_ROOT="$2"; shift 2 ;;
      --target-mode) TARGET_MODE="$2"; cli_target_mode="$2"; shift 2 ;;
      --dry-run) DRY_RUN="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) err "Unknown argument: $1"; usage; exit 1 ;;
    esac
  done

  if [ "$TARGET_MODE" != "standalone" ] && [ "$TARGET_MODE" != "solrcloud" ]; then
    err "Invalid --target-mode: ${TARGET_MODE}"
    exit 1
  fi

  load_env_file
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/.env"
  INSTANCE_NAME="${cli_instance_name:-${INSTANCE_NAME:-solr}}"
  TARGET_MODE="${cli_target_mode:-${SOLR_MODE:-$TARGET_MODE}}"

  detect_legacy_solr_home

  local ts mig_dir state_file export_dir
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  mig_dir="${MIGRATION_ROOT}/${INSTANCE_NAME}/${ts}"
  state_file="${MIGRATION_ROOT}/${INSTANCE_NAME}/LATEST_SUCCESS.state"
  export_dir="${mig_dir}/cores"

  mkdir -p "$mig_dir"

  log "Starting one-way upgrade (bare-metal -> docker)"
  log "Legacy SOLR_HOME: ${LEGACY_SOLR_HOME}"
  log "Migration dir: ${mig_dir}"

  ensure_instance_recognizable
  export_legacy_cores "$LEGACY_SOLR_HOME" "$export_dir"
  stop_legacy_service

  log "Starting/updating Docker runtime for instance ${INSTANCE_NAME}"
  # Only rebuild if Dockerfile, config, or scripts changed since last successful build.
  # Checksum file tracks the last built state.
  local build_checksum_file="${MIGRATION_ROOT}/${INSTANCE_NAME}/.build-checksum"
  local current_checksum
  current_checksum="$(
    {
      printf '%s\0' \
        "${ROOT_DIR}/Dockerfile" \
        "${ROOT_DIR}/Dockerfile.solr" \
        "${ROOT_DIR}/docker-compose.yml" \
        "${ROOT_DIR}/security.json.template" \
        "${ROOT_DIR}/init/security.json.template" \
        "${ROOT_DIR}/eLeDia-config/managed-schema" \
        "${ROOT_DIR}/eLeDia-config/solrconfig.xml" \
        "${ROOT_DIR}/init/powerinit.sh"
      find "${ROOT_DIR}/scripts" -maxdepth 1 -type f -name '*.sh' -print0
    } | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1
  )" # includes solr-tenant-cmd.sh and all runtime scripts copied by Dockerfile.solr
  local needs_build="yes"
  if [ -f "$build_checksum_file" ] && [ -f "$state_file" ]; then
    local last_checksum
    last_checksum="$(cat "$build_checksum_file" 2>/dev/null || true)"
    if [ "$current_checksum" = "$last_checksum" ]; then
      needs_build="no"
      log "No changes detected since last build — skipping --build"
    fi
  fi
  if [ "$needs_build" = "yes" ]; then
    run env "INSTANCE_NAME=${INSTANCE_NAME}" "SOLR_MODE=${TARGET_MODE}" docker compose -f "${COMPOSE_FILE}" up -d --build
    printf '%s' "$current_checksum" > "$build_checksum_file"
  else
    run env "INSTANCE_NAME=${INSTANCE_NAME}" "SOLR_MODE=${TARGET_MODE}" docker compose -f "${COMPOSE_FILE}" up -d
  fi

  import_cores_into_volume "$export_dir"

  local solr_container="${INSTANCE_NAME}-solr"
  logc "$solr_container" "restart after core import"
  run_quiet docker restart "${solr_container}"

  ensure_instance_recognizable
  write_state_marker "$state_file"
  log "Upgrade finished. State marker: ${state_file}"
}

main "$@"
