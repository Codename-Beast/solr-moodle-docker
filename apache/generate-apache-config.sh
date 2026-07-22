#!/bin/bash
# Copyright (c) 2026 eLeDia.de / Bernd Schreistetter (bsc)
# Version: v3.4.12

# =========================================
# Apache Config Generator for Solr Instances
# =========================================
# Generates Apache VirtualHost configuration from template
#
# Usage: ./generate-apache-config.sh
#        ./generate-apache-config.sh --instance kunde-a --hostname solr.example.com --port 8983
#
# =========================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/solr-instance.conf.template"
OUTPUT_DIR="${SCRIPT_DIR}/generated"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Apache Config Generator for Solr${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo ""
}

# Parse command line arguments
INSTANCE_NAME=""
HOSTNAME=""
SOLR_PORT=""
ADMIN_EMAIL="admin@localhost"
INTERACTIVE=true

while [[ $# -gt 0 ]]; do
    case $1 in
        --instance)
            INSTANCE_NAME="$2"
            INTERACTIVE=false
            shift 2
            ;;
        --hostname)
            HOSTNAME="$2"
            shift 2
            ;;
        --port)
            SOLR_PORT="$2"
            shift 2
            ;;
        --email)
            ADMIN_EMAIL="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --instance NAME    Instance name (e.g., kunde-a)"
            echo "  --hostname HOST    Full hostname (e.g., solr-kunde-a.example.com)"
            echo "  --port PORT        Solr port (e.g., 8983)"
            echo "  --email EMAIL      Admin email (default: admin@localhost)"
            echo "  --help             Show this help"
            echo ""
            echo "Interactive mode is used if no arguments are provided."
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

print_header

# Check template exists
if [[ ! -f "$TEMPLATE_FILE" ]]; then
    echo -e "${RED}Error: Template file not found: ${TEMPLATE_FILE}${NC}"
    exit 1
fi

# Interactive mode
if [[ "$INTERACTIVE" == "true" ]]; then
    echo -e "${YELLOW}Interactive Mode${NC}"
    echo "Press Ctrl+C to cancel"
    echo ""

    # Instance Name
    read -rp "Instance name (e.g., kunde-a, produktion): " INSTANCE_NAME
    if [[ -z "$INSTANCE_NAME" ]]; then
        echo -e "${RED}Error: Instance name is required${NC}"
        exit 1
    fi

    # Hostname
    read -rp "Full hostname (e.g., solr-${INSTANCE_NAME}.example.com): " HOSTNAME
    if [[ -z "$HOSTNAME" ]]; then
        echo -e "${RED}Error: Hostname is required${NC}"
        exit 1
    fi

    # Port - with auto-detection
    echo ""
    echo -e "${BLUE}Detecting used ports...${NC}"
    USED_PORTS=$(ss -tlnp 2>/dev/null | grep -oP '127\.0\.0\.1:\K898[0-9]+' | sort -u || echo "")
    if [[ -n "$USED_PORTS" ]]; then
        echo -e "Currently used Solr ports: ${YELLOW}${USED_PORTS//$'\n'/, }${NC}"
    fi

    # Find next free port
    NEXT_PORT=8983
    while ss -tlnp 2>/dev/null | grep -q "127.0.0.1:${NEXT_PORT}"; do
        ((NEXT_PORT++))
    done

    read -rp "Solr port [${NEXT_PORT}]: " SOLR_PORT
    SOLR_PORT="${SOLR_PORT:-$NEXT_PORT}"

    # Admin Email
    read -rp "Admin email [admin@localhost]: " input_email
    ADMIN_EMAIL="${input_email:-admin@localhost}"
fi

# Validate inputs
if [[ -z "$INSTANCE_NAME" ]] || [[ -z "$HOSTNAME" ]] || [[ -z "$SOLR_PORT" ]]; then
    echo -e "${RED}Error: Missing required parameters${NC}"
    echo "Required: --instance, --hostname, --port"
    exit 1
fi

# Validate port number
if ! [[ "$SOLR_PORT" =~ ^[0-9]+$ ]] || [[ "$SOLR_PORT" -lt 1024 ]] || [[ "$SOLR_PORT" -gt 65535 ]]; then
    echo -e "${RED}Error: Invalid port number: ${SOLR_PORT}${NC}"
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Generate config
OUTPUT_FILE="${OUTPUT_DIR}/solr-${INSTANCE_NAME}.conf"

echo ""
echo -e "${BLUE}Generating configuration...${NC}"
echo "  Instance:  ${INSTANCE_NAME}"
echo "  Hostname:  ${HOSTNAME}"
echo "  Port:      ${SOLR_PORT}"
echo "  Email:     ${ADMIN_EMAIL}"
echo ""

# Replace placeholders
sed -e "s|{{INSTANCE_NAME}}|${INSTANCE_NAME}|g" \
    -e "s|{{HOSTNAME}}|${HOSTNAME}|g" \
    -e "s|{{SOLR_PORT}}|${SOLR_PORT}|g" \
    -e "s|{{ADMIN_EMAIL}}|${ADMIN_EMAIL}|g" \
    "$TEMPLATE_FILE" > "$OUTPUT_FILE"

echo -e "${GREEN}Configuration generated: ${OUTPUT_FILE}${NC}"
echo ""

# Show installation instructions
echo -e "${YELLOW}Installation Instructions:${NC}"
echo ""
echo "  1. Copy SSL config (once per server):"
echo -e "     ${BLUE}sudo cp ${SCRIPT_DIR}/ssl-common.conf /etc/apache2/conf-available/${NC}"
echo -e "     ${BLUE}sudo nano /etc/apache2/conf-available/ssl-common.conf${NC}  # Adjust certificate paths!"
echo -e "     ${BLUE}sudo a2enconf ssl-common${NC}"
echo ""
echo "  2. Copy VirtualHost config:"
echo -e "     ${BLUE}sudo cp ${OUTPUT_FILE} /etc/apache2/sites-available/${NC}"
echo ""
echo "  3. Enable required modules:"
echo -e "     ${BLUE}sudo a2enmod ssl proxy proxy_http headers rewrite${NC}"
echo ""
echo "  4. Enable site:"
echo -e "     ${BLUE}sudo a2ensite solr-${INSTANCE_NAME}.conf${NC}"
echo ""
echo "  5. Test and reload:"
echo -e "     ${BLUE}sudo apache2ctl configtest${NC}"
echo -e "     ${BLUE}sudo systemctl reload apache2${NC}"
echo ""

# Show .env hint
echo -e "${YELLOW}Don't forget to set in your Solr .env:${NC}"
echo "  INSTANCE_NAME=${INSTANCE_NAME}"
echo "  SOLR_PORT=${SOLR_PORT}"
echo "  SOLR_HOSTNAME=${HOSTNAME}"
echo ""

echo -e "${GREEN}Done!${NC}"
