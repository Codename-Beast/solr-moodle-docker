FROM alpine:3.20
# =========================================
# Solr Init Container
# Developer: BSC Bernd Schreistetter
# Company: Eledia.de
# Version: v2.1
# =========================================
RUN apk add --no-cache \
    openssl \
    coreutils \
    bash \
    curl \
    ca-certificates

# Create working directories
RUN mkdir -p /config /workspace /var/solr/data /prometheus-config /init

# Copy configuration files
COPY config/ /config/
COPY init/security.json.template /init/security.json.template
COPY init/powerinit.sh /init/powerinit.sh

# Make init script executable
RUN chmod +x /init/powerinit.sh

# Set working directory
WORKDIR /

ENTRYPOINT ["/init/powerinit.sh"]
