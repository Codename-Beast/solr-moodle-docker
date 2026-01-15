FROM alpine:3.20@sha256:1e42bbe2508154c9126d48c2b8a75420c3544343bf86fd041fb7527e017a4b4a
# =========================================
# Solr Init Container
# Developer: BSC Bernd Schreistetter
# Company: Eledia.de
# Version: v2.2
# =========================================
RUN apk add --no-cache \
    openssl \
    coreutils \
    bash \
    curl \
    ca-certificates \
    findutils && \
    mkdir -p /config /workspace /var/solr/data /prometheus-config /init

# Copy configuration files
COPY config/ /config/
COPY init/security.json.template /init/security.json.template
COPY init/powerinit.sh /init/powerinit.sh

# Make init script executable and set permissions
RUN chmod +x /init/powerinit.sh

# Set working directory
WORKDIR /

ENTRYPOINT ["/init/powerinit.sh"]
