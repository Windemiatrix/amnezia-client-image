# =============================================================================
# Dockerfile — AmneziaWG VPN client (userspace)
# Multi-stage build: Go daemon + C CLI tools + Alpine runtime
# =============================================================================

# --- Build arguments ---------------------------------------------------------
ARG AMNEZIAWG_GO_VERSION=v0.2.16
ARG AMNEZIAWG_TOOLS_VERSION=v1.0.20250903
ARG ALPINE_VERSION=3.21
ARG GO_VERSION=1.24

# =============================================================================
# Stage 1: Build amneziawg-go (userspace VPN daemon)
# =============================================================================
FROM golang:${GO_VERSION}-alpine AS builder-go

ARG AMNEZIAWG_GO_VERSION

RUN apk add --no-cache git make

RUN git clone --branch "${AMNEZIAWG_GO_VERSION}" --depth 1 \
        https://github.com/amnezia-vpn/amneziawg-go.git /src/amneziawg-go

WORKDIR /src/amneziawg-go

ENV CGO_ENABLED=0

RUN go build -v -trimpath -ldflags="-s -w" -o /usr/bin/amneziawg-go

# =============================================================================
# Stage 2: Build amneziawg-tools (awg + awg-quick)
# =============================================================================
FROM alpine:${ALPINE_VERSION} AS builder-tools

ARG AMNEZIAWG_TOOLS_VERSION

RUN apk add --no-cache git make gcc musl-dev linux-headers

RUN git clone --branch "${AMNEZIAWG_TOOLS_VERSION}" --depth 1 \
        https://github.com/amnezia-vpn/amneziawg-tools.git /src/amneziawg-tools

WORKDIR /src/amneziawg-tools/src

RUN make -j"$(nproc)" && \
    make install DESTDIR=/build PREFIX=/usr WITH_WGQUICK=yes WITH_BASHCOMPLETION=no WITH_SYSTEMDUNITS=no

# =============================================================================
# Stage 3: Runtime
# =============================================================================
FROM alpine:${ALPINE_VERSION} AS runtime

# OCI labels
LABEL org.opencontainers.image.title="amnezia-client-image" \
      org.opencontainers.image.description="AmneziaWG VPN client (userspace Go implementation)" \
      org.opencontainers.image.source="https://github.com/Windemiatrix/amnezia-client-image" \
      org.opencontainers.image.licenses="MIT"

# Runtime dependencies for awg-quick (bash script) and networking
RUN apk add --no-cache \
        bash \
        jq \
        iproute2 \
        iptables \
        ip6tables \
        openresolv \
        iputils-ping \
        bind-tools \
    && rm -rf /var/cache/apk/*

# Copy binaries from build stages
COPY --from=builder-go    /usr/bin/amneziawg-go    /usr/bin/amneziawg-go
COPY --from=builder-tools /build/usr/bin/awg       /usr/bin/awg
COPY --from=builder-tools /build/usr/bin/awg-quick /usr/bin/awg-quick

# Copy scripts
COPY scripts/entrypoint.sh  /entrypoint.sh
COPY scripts/healthcheck.sh /healthcheck.sh
COPY scripts/sysctl-wrapper.sh /usr/local/bin/sysctl
RUN chmod +x /entrypoint.sh /healthcheck.sh /usr/local/bin/sysctl

# Environment defaults
ENV WG_CONFIG_FILE=/config/wg0.conf \
    LOG_LEVEL=info \
    KILL_SWITCH=1 \
    HEALTH_CHECK_HOST=1.1.1.1

# Config volume
VOLUME /config

# Health check
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
    CMD /healthcheck.sh

ENTRYPOINT ["/entrypoint.sh"]
