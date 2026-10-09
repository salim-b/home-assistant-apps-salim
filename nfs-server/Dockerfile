# https://developers.home-assistant.io/docs/apps/configuration#app-dockerfile
ARG BUILD_FROM=ghcr.io/home-assistant/base:3.24
FROM ${BUILD_FROM}

# Install requirements for app
# NOTE: nfs-utils is unpinned deliberately: Alpine minor releases repoint
# package versions, and the app image is rebuilt regularly.
# hadolint ignore=DL3018
RUN apk add --no-cache \
  nfs-utils

# Create necessary system directories (exportfs keeps its export table state
# in /var/lib/nfs)
# hadolint ignore=DL3059
RUN mkdir -p /var/lib/nfs

# Copy root filesystem
COPY --link rootfs /

LABEL \
    org.opencontainers.image.title="Home Assistant app: NFS Server" \
    org.opencontainers.image.description="Network File System (NFS) server for Home Assistant." \
    org.opencontainers.image.source="https://github.com/salim-b/home-assistant-apps-salim" \
    org.opencontainers.image.licenses="Apache License 2.0"

# Health check: rpc.nfsd only starts the NFS server in the kernel and then
# exits, hence probe the kernel's NFS listener on TCP port 2049 (see
# rootfs/usr/bin/nfsd-healthcheck).
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["/usr/bin/nfsd-healthcheck"]
