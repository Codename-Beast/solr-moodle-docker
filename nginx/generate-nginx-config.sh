#!/bin/bash
# Copyright (c) 2026 eLeDia.de / Bernd Schreistetter (bsc)
# Version: v3.4.11

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/solr-instance.conf.template"
OUTPUT_DIR="${SCRIPT_DIR}/generated"

INSTANCE_NAME=""
HOSTNAME=""
SOLR_PORT=""
INTERACTIVE=true

usage() {
  cat <<'EOF'
Usage: nginx/generate-nginx-config.sh [options]

Options:
  --instance NAME    Instance name, e.g. kunde-a or produktion
  --hostname HOST    Public hostname, e.g. solr-kunde-a.example.com
  --port PORT        Local Solr port, e.g. 8983
  -h, --help         Show this help

The generated config contains two explicit upstream variants:
  A) proxy on host:          http://127.0.0.1:<port>
  B) proxy in Docker network: http://solr:8983
Enable exactly one proxy_pass line in the generated file.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --instance) INSTANCE_NAME="$2"; INTERACTIVE=false; shift 2 ;;
    --hostname) HOSTNAME="$2"; shift 2 ;;
    --port) SOLR_PORT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done

printf '\n=== Nginx Config Generator for Solr ===\n\n'
[ -f "$TEMPLATE_FILE" ] || { printf 'ERROR: missing template: %s\n' "$TEMPLATE_FILE" >&2; exit 1; }

if [ "$INTERACTIVE" = "true" ]; then
  read -rp "Instance name (e.g. kunde-a): " INSTANCE_NAME
  read -rp "Public hostname (e.g. solr-${INSTANCE_NAME}.example.com): " HOSTNAME
  read -rp "Solr port [8983]: " SOLR_PORT
  SOLR_PORT="${SOLR_PORT:-8983}"
fi

[ -n "$INSTANCE_NAME" ] || { printf 'ERROR: --instance is required\n' >&2; exit 1; }
[ -n "$HOSTNAME" ] || { printf 'ERROR: --hostname is required\n' >&2; exit 1; }
[ -n "$SOLR_PORT" ] || { printf 'ERROR: --port is required\n' >&2; exit 1; }
case "$SOLR_PORT" in ''|*[!0-9]*) printf 'ERROR: invalid port: %s\n' "$SOLR_PORT" >&2; exit 1 ;; esac

mkdir -p "$OUTPUT_DIR"
OUTPUT_FILE="${OUTPUT_DIR}/solr-${INSTANCE_NAME}.conf"

sed -e "s|{{INSTANCE_NAME}}|${INSTANCE_NAME}|g" \
    -e "s|{{HOSTNAME}}|${HOSTNAME}|g" \
    -e "s|{{SOLR_PORT}}|${SOLR_PORT}|g" \
    "$TEMPLATE_FILE" > "$OUTPUT_FILE"

printf 'Generated: %s\n\n' "$OUTPUT_FILE"
printf 'Install on host Nginx:\n'
printf '  sudo cp %s /etc/nginx/sites-available/\n' "$OUTPUT_FILE"
printf '  sudo ln -sf /etc/nginx/sites-available/solr-%s.conf /etc/nginx/sites-enabled/solr-%s.conf\n' "$INSTANCE_NAME" "$INSTANCE_NAME"
printf '  sudo nginx -t\n'
printf '  sudo systemctl reload nginx\n\n'
printf 'Upstream variants are documented in the generated file. Enable exactly one proxy_pass line.\n'
