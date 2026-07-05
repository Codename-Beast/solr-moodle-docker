#!/bin/bash
# Copyright (c) 2026 eLeDia.de / Bernd Schreistetter (bsc)
# Version: v3.4.11
#
# eLeDia Test Tenant Generator — Generiert N Tenant-Einträge für tenants.env
# Part of the eLeDia Solr Multi-Tenant Docker Stack.
#
# Usage: ./generate-test-tenants.sh [ANZAHL] [AUSGABEDATEI]
#
# Beispiele:
#   ./generate-test-tenants.sh 500 /tmp/tenants-500.env
#   ./generate-test-tenants.sh 50  /tmp/tenants-50.env  (klein)
#   ./generate-test-tenants.sh 1000 /tmp/tenants-1000.env (stress)

set -euo pipefail

COUNT="${1:-500}"
OUTPUT="${2:-/tmp/tenants-${COUNT}.env}"

echo "=== Generating $COUNT test tenants → $OUTPUT ==="

# Header
cat > "$OUTPUT" <<'HEADER'
# =========================================
# Test-Tenants — Generiert automatisiert
# WARNING: Nur für Testzwecke!
# =========================================
HEADER

# Funktion: Passwort generieren
gen_pass() {
  openssl rand -base64 36 | tr -d '/+=' | head -c 32
}

# Pattern für verschiedene Tenant-Typen
declare -a PREFIXES=(
  "schule" "moodle" "campus" "akademie" "institut" "bildung" "kurse"
  "training" "webinar" "video" "learn" "edu" "course" "academy"
)

for i in $(seq 1 "$COUNT"); do
  PREFIX="${PREFIXES[$((i % ${#PREFIXES[@]}))]}"
  NAME="${PREFIX}_$(printf '%04d' "$i")"

  # Je 5. Tenant hat 2 Cores, je 10. hat 3, Rest hat 1
  if (( i % 10 == 0 )); then
    CORES="eLeDia_core_${NAME}_a,eLeDia_core_${NAME}_b,eLeDia_core_${NAME}_c"
  elif (( i % 5 == 0 )); then
    CORES="eLeDia_core_${NAME}_a,eLeDia_core_${NAME}_b"
  else
    CORES="eLeDia_core_${NAME}"
  fi

  USER="solr_${NAME}"
  PASS="$(gen_pass)"

  # Je 3. Tenant ist inaktiv
  if (( i % 3 == 0 )); then
    ACTIVE="false"
  else
    ACTIVE="true"
  fi

  {
    echo "TENANT_${NAME}_CORES=${CORES}"
    echo "TENANT_${NAME}_USER=${USER}"
    echo "TENANT_${NAME}_PASS=${PASS}"
    echo "TENANT_${NAME}_ACTIVE=${ACTIVE}"
  } >> "$OUTPUT"
done

LINES=$(wc -l < "$OUTPUT")
ENTRIES=$(grep -c '^TENANT_.*_CORES=' "$OUTPUT" || true)
FILESIZE=$(du -h "$OUTPUT" | cut -f1)

echo "=== Done: $ENTRIES tenants, $LINES lines, $FILESIZE ==="
