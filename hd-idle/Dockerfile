# https://developers.home-assistant.io/docs/apps/configuration#app-dockerfile
ARG BUILD_FROM=ghcr.io/home-assistant/base:3.24
FROM ${BUILD_FROM}

# hd-idle (a static Go binary) from the Alpine community repo, version
# PINNED (full pkgver-pkgrel, DL3018-compliant): the app's argument
# generation encodes hd-idle's CLI semantics (see rootfs/usr/bin/hd-idle-genargs
# and hd-idle/KNOWLEDGE.md), so package changes must be explicit app changes -
# each new package version becomes an app release (bump pin + config.yaml
# version + changelog). Alpine stable branches repoint package versions
# (pkgrel bumps; the binary index then serves only the current one, so a
# stale pin would break the build): validate.py's apk-drift check (running
# in the daily CI cron) flags the mismatch with that workflow. This differs
# deliberately from nfs-server's floating nfs-utils - the policy background
# is in the repository-root KNOWLEDGE.md (apk package version policy).
# smartmontools: powers the drive-PM treatment (hd-idle-pmfix, option
# disable_drive_pm - see hd-idle/KNOWLEDGE.md).
RUN apk add --no-cache \
  hd-idle=1.22-r7 \
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
