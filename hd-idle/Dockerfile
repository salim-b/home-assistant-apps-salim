# https://contributors.home-assistant.io/apps/guides/dockerfile/
ARG BUILD_FROM=ghcr.io/home-assistant/base:3.24
FROM ${BUILD_FROM}

# hd-idle (a static Go binary) and smartmontools (powers hd-idle-pmfix, see hd-idle/KNOWLEDGE.md), versions PINNED
# (full pkgver-pkgrel): the app's argument generation encodes hd-idle's CLI semantics, so package changes must be
# explicit app releases (bump pin + config.yaml version + changelog). Policy background and the apk-drift check:
# repository-root KNOWLEDGE.md (apk package version policy).
RUN apk add --no-cache \
  hd-idle=1.22-r8 \
  smartmontools=7.5-r0

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
