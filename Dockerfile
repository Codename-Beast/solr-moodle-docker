# Copyright (c) 2026 eLeDia.de / Bernd Schreistetter (bsc)

FROM alpine:3.22@sha256:310c62b5e7ca5b08167e4384c68db0fd2905dd9c7493756d356e893909057601
# =========================================
# Solr Init Container
# Version: v3.4.11
# Multi-Tenant Support
# =========================================
# Update musl to fix CVE-2025-26519
RUN apk upgrade --no-cache musl musl-utils

RUN apk add --no-cache \
    openssl \
    coreutils \
    bash \
    curl \
    ca-certificates \
    findutils \
    jq && \
    mkdir -p /config /workspace /var/solr/data /init

# Copy configuration files
# Copy config into both the default runtime path and an image-owned fallback.
# The fallback is used when Docker-in-Docker host bind mounts create an empty /config.
COPY eLeDia-config/ /config/
COPY eLeDia-config/ /config-image/
COPY init/security.json.template /init/security.json.template
COPY init/powerinit.sh /init/powerinit.sh
COPY scripts/ /opt/solr/scripts/

# Make init script executable and set permissions
RUN chmod +x /init/powerinit.sh && \
    chmod +x /opt/solr/scripts/*.sh

# Set working directory
WORKDIR /

ENTRYPOINT ["/init/powerinit.sh"]
