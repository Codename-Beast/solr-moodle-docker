#!/bin/bash
# Copyright (c) 2026 eLeDia.de / Bernd Schreistetter (bsc)
# Version: v3.4.12
#
# eLeDia Solr Tenant Dispatcher
# Sources modular sub-scripts and dispatches commands.
# Part of the eLeDia Solr Multi-Tenant Docker Stack.
#
# Usage: solr-tenant.sh <command> [options]
# Run 'solr-tenant.sh usage' for full command list.

set -euo pipefail

if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  printf 'ERROR: solr-tenant.sh requires Bash 4 or newer (found: %s).\n' "${BASH_VERSION:-unknown}" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source modules in dependency order
source "${SCRIPT_DIR}/solr-tenant-api.sh"
source "${SCRIPT_DIR}/solr-tenant-core.sh"
source "${SCRIPT_DIR}/solr-tenant-security.sh"
source "${SCRIPT_DIR}/solr-tenant-cmd.sh"

# ---------------------------------------------------------------------------
# eLeDia Dispatcher
# ---------------------------------------------------------------------------
cmd="${1:-}"; shift || true
case "$cmd" in
  create)       cmd_create "$@" ;;
  delete)       cmd_delete "$@" ;;
  enable)       cmd_enable "$@" ;;
  passwd)       cmd_passwd "$@" ;;
  list)         cmd_list ;;
  info)         cmd_info "$@" ;;
  core-add)     cmd_core_add "$@" ;;
  core-remove)  cmd_core_remove "$@" ;;
  apply)        cmd_apply ;;
  sync-sot)       cmd_sync_sot ;;
  rebuild-permissions) cmd_rebuild_permissions ;;
  config-repair) cmd_config_repair ;;
  healthcheck)   cmd_healthcheck ;;
  drift-detect)   cmd_drift_detect ;;
  drift-remediate) cmd_drift_remediate ;;
  export)         cmd_export ;;
  runtime-truth)  cmd_runtime_truth ;;
  caddy-config) cmd_caddy_config "$@" ;;
  usage|help|-h|--help) usage ;;
  "")           usage; exit 1 ;;
  *)            printf 'Unknown command: %s\n' "$cmd" >&2; usage; exit 1 ;;
esac
