#!/usr/bin/env bash
set -Eeuo pipefail

# Export/Import + Mode switch helper for Standalone <-> SolrCloud portability.
# Goal: keep Moodle-facing API continuity while switching runtime mode.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

log() { printf '[mode-portability] %s\n' "$*"; }
err() { printf '[mode-portability][ERROR] %s\n' "$*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }
}

load_env() {
  [ -f "$ENV_FILE" ] || { err ".env not found at $ENV_FILE"; exit 1; }
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

instance() { printf '%s' "${INSTANCE_NAME:-solr}"; }
container_name() { printf '%s-solr' "$(instance)"; }
tenants_file() { printf '%s/tenants.env' "$ROOT_DIR"; }

admin_auth() {
  if [ -z "${SOLR_ADMIN_PASSWORD:-}" ]; then
    err "SOLR_ADMIN_PASSWORD missing in .env"
    exit 1
  fi
  printf 'admin:%s' "$SOLR_ADMIN_PASSWORD"
}

detect_mode() {
  if [ "${SOLR_MODE:-}" = "solrcloud" ]; then
    printf 'solrcloud'
  else
    printf 'standalone'
  fi
}

wait_solr_ready() {
  local waited=0 code
  while [ "$waited" -lt 180 ]; do
    code="$(curl -s -o /dev/null -w '%{http_code}' -u "$(admin_auth)" "http://127.0.0.1:${SOLR_PORT:-8983}/solr/admin/info/system" || true)"
    [ "$code" = "200" ] && return 0
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}

export_manifest() {
  local out="${1:-${ROOT_DIR}/mode-portability-export.json}"
  local mode now core_json ten_json tmp
  mode="$(detect_mode)"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  tmp="$(mktemp)"

  if [ "$mode" = "solrcloud" ]; then
    core_json="$(curl -s -u "$(admin_auth)" "http://127.0.0.1:${SOLR_PORT:-8983}/solr/admin/collections?action=LIST&wt=json" \
      | jq -c '.collections // []')"
  else
    core_json="$(curl -s -u "$(admin_auth)" "http://127.0.0.1:${SOLR_PORT:-8983}/solr/admin/cores?action=STATUS&wt=json" \
      | jq -c '(.status // {}) | keys')"
  fi

  if [ -f "$(tenants_file)" ]; then
    ten_json="$(awk -F= '
      /^TENANT_.*_CORES=/ {
        n=$1; sub(/^TENANT_/,"",n); sub(/_CORES$/,"",n);
        cores=$2;
        gsub(/ /,"",cores);
        arr="[\"" gensub(/,/,"\",\"","g",cores) "\"]";
        users[n]=arr;
      }
      /^TENANT_.*_ACTIVE=/ {
        n=$1; sub(/^TENANT_/,"",n); sub(/_ACTIVE$/,"",n);
        active[n]=$2;
      }
      END {
        first=1;
        printf "[";
        for (n in users) {
          if (!first) printf ",";
          first=0;
          a=(active[n]=="false"?"false":"true");
          printf "{\"name\":\"%s\",\"active\":%s,\"cores\":%s}", n, a, users[n];
        }
        printf "]";
      }
    ' "$(tenants_file)")"
  else
    ten_json='[]'
  fi

  jq -n \
    --arg version "1" \
    --arg generated_at "$now" \
    --arg from_mode "$mode" \
    --arg solr_version "${SOLR_VERSION:-unknown}" \
    --argjson cores "$core_json" \
    --argjson tenants "$ten_json" \
    '{
      schema: "solr-mode-portability",
      schema_version: $version,
      generated_at: $generated_at,
      from_mode: $from_mode,
      solr_version: $solr_version,
      cores_or_collections: $cores,
      tenants: $tenants
    }' > "$tmp"

  mv "$tmp" "$out"
  log "Export written: $out"
}

import_manifest() {
  local in="$1"
  [ -f "$in" ] || { err "Manifest not found: $in"; exit 1; }

  local container tenant_cmd
  container="$(container_name)"
  tenant_cmd="docker exec $container /opt/solr/scripts/solr-tenant.sh"

  local count
  count="$(jq '.tenants | length' "$in")"
  if [ "$count" -eq 0 ]; then
    log "No tenants in manifest, nothing to import"
    return 0
  fi

  local i name active cores
  for i in $(seq 0 $((count - 1))); do
    name="$(jq -r ".tenants[$i].name" "$in")"
    active="$(jq -r ".tenants[$i].active" "$in")"
    cores="$(jq -r ".tenants[$i].cores | join(\",\")" "$in")"

    if [ -z "$name" ] || [ -z "$cores" ] || [ "$name" = "null" ] || [ "$cores" = "null" ]; then
      continue
    fi

    if ! $tenant_cmd info "$name" >/dev/null 2>&1; then
      $tenant_cmd create "$name" --cores "$cores" >/dev/null 2>&1 || true
    fi

    IFS=',' read -r -a c_arr <<< "$cores"
    for c in "${c_arr[@]}"; do
      c="$(echo "$c" | tr -d ' ')"
      [ -z "$c" ] && continue
      $tenant_cmd core-add "$name" --core "$c" >/dev/null 2>&1 || true
    done

    # Idempotent active/deactivate: only change if current state differs
    local current_active
    current_active="$($tenant_cmd info "$name" 2>/dev/null | awk '/Active:/ {print $2}')"
    if [ "$active" = "true" ] && [ "$current_active" = "false" ]; then
      $tenant_cmd enable "$name" >/dev/null 2>&1 || true
    elif [ "$active" = "false" ] && [ "$current_active" != "false" ]; then
      $tenant_cmd delete "$name" --force >/dev/null 2>&1 || true
    fi
  done

  $tenant_cmd apply >/dev/null 2>&1 || true
  log "Import applied from: $in"
}

set_mode_in_env() {
  local to="$1"
  if [ "$to" = "standalone" ]; then
    sed -i 's/^SOLR_MODE=.*/SOLR_MODE=/' "$ENV_FILE"
  else
    sed -i 's/^SOLR_MODE=.*/SOLR_MODE=solrcloud/' "$ENV_FILE"
  fi
}

switch_mode() {
  local to="$1"
  local build_flag="${2:-build}"

  if [ "$to" != "standalone" ] && [ "$to" != "solrcloud" ]; then
    err "Invalid target mode: $to"
    exit 1
  fi

  local from manifest
  from="$(detect_mode)"
  if [ "$from" = "$to" ]; then
    log "Already in mode: $to"
    return 0
  fi

  manifest="${ROOT_DIR}/.mode-switch-${from}-to-${to}.json"
  export_manifest "$manifest"

  set_mode_in_env "$to"
  if [ "$build_flag" = "nobuild" ]; then
    (cd "$ROOT_DIR" && docker compose up -d)
  else
    (cd "$ROOT_DIR" && docker compose up -d --build)
  fi

  if ! wait_solr_ready; then
    err "Solr not ready after mode switch to ${to}"
    exit 1
  fi

  import_manifest "$manifest"
  log "Mode switch done: $from -> $to"
}

usage() {
  cat <<'EOF'
Usage:
  scripts/solr-mode-portability.sh export [--out FILE]
  scripts/solr-mode-portability.sh import --in FILE
  scripts/solr-mode-portability.sh switch --to standalone|solrcloud [--no-build]

Examples:
  scripts/solr-mode-portability.sh export --out /tmp/solr-portability.json
  scripts/solr-mode-portability.sh switch --to solrcloud
  scripts/solr-mode-portability.sh switch --to standalone --no-build
EOF
}

main() {
  require_cmd jq
  require_cmd curl
  require_cmd docker
  load_env

  local cmd="${1:-}"; shift || true
  case "$cmd" in
    export)
      local out="${ROOT_DIR}/mode-portability-export.json"
      while [ $# -gt 0 ]; do
        case "$1" in
          --out) out="$2"; shift 2 ;;
          *) err "Unknown arg: $1"; usage; exit 1 ;;
        esac
      done
      export_manifest "$out"
      ;;
    import)
      local in=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --in) in="$2"; shift 2 ;;
          *) err "Unknown arg: $1"; usage; exit 1 ;;
        esac
      done
      [ -n "$in" ] || { err "--in is required"; exit 1; }
      import_manifest "$in"
      ;;
    switch)
      local to=""; local build="build"
      while [ $# -gt 0 ]; do
        case "$1" in
          --to) to="$2"; shift 2 ;;
          --no-build) build="nobuild"; shift ;;
          *) err "Unknown arg: $1"; usage; exit 1 ;;
        esac
      done
      [ -n "$to" ] || { err "--to is required"; exit 1; }
      switch_mode "$to" "$build"
      ;;
    *)
      usage; exit 1 ;;
  esac
}

main "$@"
