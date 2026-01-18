FROM alpine:3.20@sha256:1e42bbe2508154c9126d48c2b8a75420c3544343bf86fd041fb7527e017a4b4a

# =========================================
# Solr Init Container
# Developer: BSC Bernd Schreistetter
# Company: Eledia.de
# Version: v2.3
# Fix CVE-2025-26519
# =========================================
# This Dockerfile handles all BUILD-TIME operations from powerinit.sh
# Runtime operations (env loading, password generation, core management)
# remain in powerinit.sh as they depend on runtime environment variables
# =========================================

# Security: Update musl to fix CVE-2025-26519
# Install all required packages at build time
# These packages are used by powerinit.sh at runtime:
# - openssl: password hashing, random generation, checksums
# - coreutils: advanced file operations (dd, sha256sum)
# - bash: script execution
# - curl: health checks / API calls
# - ca-certificates: SSL/TLS verification
# - findutils: advanced file searching
RUN apk upgrade --no-cache musl musl-utils && \
    apk add --no-cache \
        openssl \
        coreutils \
        bash \
        curl \
        ca-certificates \
        findutils

# Copy static configuration files (build-time)
# These are templates that will be used by powerinit.sh at runtime
COPY config/ /config/
COPY init/security.json.template /init/security.json.template
COPY init/powerinit.sh /init/powerinit.sh

# Create all required directories at build time
# /config:            Template configurations for Solr cores
# /workspace:         Working directory for temporary operations
# /var/solr/data:     Persistent Solr data (volumes mounted here)
# /prometheus-config: Prometheus configuration with runtime credentials
# /init:              Initialization scripts and templates
# Set executable permissions on init script (build-time)
# Permissions on /var/solr/data will be set at runtime by powerinit.sh
RUN mkdir -p \
        /config \
        /workspace \
        /var/solr/data \
        /prometheus-config \
        /init && \
    chmod +x /init/powerinit.sh && \
    chmod 644 /init/security.json.template && \
    chmod 755 /init && \
    chmod -R 755 /config

# Set working directory
WORKDIR /

# Runtime operations handled by powerinit.sh:
# - Load environment variables from .env files
# - Generate/validate secure passwords
# - Create/update security.json with hashed credentials
# - Manage Solr cores (create/rename/delete based on env vars)
# - Generate Prometheus config with plaintext credentials
# - Set proper file permissions on volumes (8983:8983)
# - Sync filesystem changes (sync)

ENTRYPOINT ["/init/powerinit.sh"]
