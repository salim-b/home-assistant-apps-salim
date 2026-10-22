# https://contributors.home-assistant.io/apps/guides/dockerfile/
ARG BUILD_FROM=ghcr.io/home-assistant/base:3.24
FROM ${BUILD_FROM}

# Pinned apk versions: the app's argument generation encodes hd-idle's CLI, so package changes must be explicit app
# releases (hd-idle/KNOWLEDGE.md §"CLI-only configuration"; policy: repository-root KNOWLEDGE.md §"apk package version policy").
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

# hd-idle exits (log.Fatal) when it loses /proc/diskstats: probe the process and the stats file.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["/usr/bin/hd-idle-healthcheck"]
