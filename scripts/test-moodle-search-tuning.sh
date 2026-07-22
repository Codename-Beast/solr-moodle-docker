#!/bin/bash
# Copyright (c) 2026 eLeDia.de / Bernd Schreistetter (bsc)
# Version: v3.4.12
#
# Compare Moodle/Solr search query profiles against an existing indexed core.
# This script does not change Solr state. It is intended for operator tuning and CI smoke checks.

set -euo pipefail

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [ -r .env ]; then
  # shellcheck disable=SC1091
  . ./.env
fi

SOLR_HOST="${SOLR_HOST:-127.0.0.1}"
SOLR_PORT="${SOLR_PORT:-8983}"
SOLR_CORE="${SOLR_CORE:-${SOLR_CORE_NAME:-eLeDia_core}}"
SOLR_USER="${SOLR_USER:-${SOLR_ADMIN_USER:-admin}}"
SOLR_PASS="${SOLR_PASS:-${SOLR_ADMIN_PASSWORD:-}}"
SEARCH_TERMS="${SEARCH_TERMS:-PDF_MARKER_ELEDIA_SOLR_TIKA_1784763001 DOCX_MARKER_ELEDIA_SOLR_TIKA_1784763002 PPTX_MARKER_ELEDIA_SOLR_TIKA_1784763003 Rechnungsfreigabe Vertragsanlage Schulungsfolie}"
ROWS="${ROWS:-10}"
BASE_URL="http://${SOLR_HOST}:${SOLR_PORT}/solr/${SOLR_CORE}"
AUTH_ARGS=()
if [ -n "$SOLR_PASS" ]; then
  AUTH_ARGS=(-u "${SOLR_USER}:${SOLR_PASS}")
fi

need() {
  command -v "$1" >/dev/null 2>&1 || { printf 'ERROR: required command missing: %s\n' "$1" >&2; exit 2; }
}
need curl
need jq

query_profile() {
  local label="$1" path="$2" term="$3"
  shift 3
  local tmp code time_total num_found qtime
  tmp="$(mktemp)"
  local query_args=(--data-urlencode "q=${term}")
  if [ "$#" -gt 0 ]; then
    query_args=("$@")
  fi
  code="$(curl -sS -o "$tmp" -w '%{http_code} %{time_total}' "${AUTH_ARGS[@]}" --get \
    "${query_args[@]}" \
    --data "rows=${ROWS}" \
    --data "wt=json" \
    "${BASE_URL}${path}" 2>/dev/null || printf '000 0')"
  time_total="${code#* }"
  code="${code%% *}"
  num_found="$(jq -r '.response.numFound // 0' "$tmp" 2>/dev/null || printf '%s' '0')"
  qtime="$(jq -r '.responseHeader.QTime // -1' "$tmp" 2>/dev/null || printf '%s' '-1')"
  printf '%s|%s|http=%s|numFound=%s|QTime_ms=%s|curl_s=%s\n' "$label" "$term" "$code" "$num_found" "$qtime" "$time_total"
  rm -f "$tmp"
}

printf 'Moodle/Solr search tuning comparison\n'
printf 'endpoint=%s core=%s rows=%s\n' "$BASE_URL" "$SOLR_CORE" "$ROWS"
printf 'profile|term|http|numFound|QTime_ms|curl_s\n'

for term in $SEARCH_TERMS; do
  # Baseline close to generic /select usage.
  query_profile 'select_default' '/select' "$term"

  # Explicit content/file-content profile: shows whether body text and Tika extraction are usable.
  query_profile 'select_content_or_file' '/select' "$term" \
    --data-urlencode "q=content:${term} OR solr_filecontent:${term} OR title:${term}"

  # Optimized eDisMax handler from eLeDia solrconfig.xml.
  query_profile 'moodle_edismax' '/moodle' "$term"

  # Same optimized handler with Moodle-like area filter for activity resources.
  query_profile 'moodle_edismax_resource_fq' '/moodle' "$term" \
    --data-urlencode "q=${term}" \
    --data 'fq=areaid:mod_resource-activity'
done
