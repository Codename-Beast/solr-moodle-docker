#!/bin/bash
# Copyright (c) 2026 Eledia GmbH / Bernd Schreistetter
# SPDX-License-Identifier: MIT
# Version: v3.1.0
#
# solr-tenant.sh — Main dispatcher
# Sources modular sub-scripts and dispatches commands.
#
# Usage: solr-tenant.sh <command> [options]
# Run 'solr-tenant.sh usage' for full command list.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source modules in dependency order
source "${SCRIPT_DIR}/solr-tenant-api.sh"
source "${SCRIPT_DIR}/solr-tenant-core.sh"
source "${SCRIPT_DIR}/solr-tenant-security.sh"
source "${SCRIPT_DIR}/solr-tenant-cmd.sh"

# ---------------------------------------------------------------------------
# Dispatch
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
  sync-sot)     cmd_sync_sot ;;
  export)       cmd_export ;;
  caddy-config) cmd_caddy_config "$@" ;;
  usage|help|-h|--help) usage ;;
  "")           usage; exit 1 ;;
  *)            printf 'Unknown command: %s\n' "$cmd" >&2; usage; exit 1 ;;
esac
