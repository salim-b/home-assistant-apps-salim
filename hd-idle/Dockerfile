# https://developers.home-assistant.io/docs/apps/configuration#app-dockerfile
ARG BUILD_FROM=ghcr.io/home-assistant/base:3.24
FROM ${BUILD_FROM}

# hd-idle (a static Go binary) from the Alpine community repo; unpinned
# deliberately: Alpine minor releases repoint package versions, and the app
# image is rebuilt regularly. The package installs the binary to
# /usr/sbin/hd-idle (no runtime dependencies beyond musl).
# hadolint ignore=DL3018
RUN apk add --no-cache \
  hd-idle

# Copy root filesystem
COPY --link rootfs /

LABEL \
    org.opencontainers.image.title="Home Assistant app: hd-idle" \
    org.opencontainers.image.description="Spin down idle hard disks (USB, SATA) automatically using hd-idle." \
    org.opencontainers.image.source="https://github.com/salim-b/home-assistant-apps-salim" \
    org.opencontainers.image.licenses="Apache License 2.0"

# Health check: hd-idle is a long-running daemon which exits (via log.Fatal)
# if it loses access to /proc/diskstats; probe the process and the stats file.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["/usr/bin/hd-idle-healthcheck"]
