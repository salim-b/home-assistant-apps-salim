# https://contributors.home-assistant.io/apps/guides/dockerfile/
ARG BUILD_FROM=ghcr.io/home-assistant/base:3.24
FROM ${BUILD_FROM}

# Pinned apk versions: the app's runtime logic encodes nfs-utils's interface (exportfs's export-table/fsid semantics
# in nfsd-apply, the rpc.nfsd CLI in nfsd-start, nfsdcld's client-tracking store format), so package changes must be
# explicit app releases (nfs-server/KNOWLEDGE.md §"Export-cache and fsid semantics", §"`rpc.nfsd` is not a daemon",
# §"NFSv4 client state recovery (nfsdcld + per-netns rpc_pipefs)"; policy: repository-root KNOWLEDGE.md §"apk package version policy").
RUN apk add --no-cache \
  nfs-utils=2.6.4-r6

# Create necessary system directories (exportfs keeps its export table state in /var/lib/nfs)
# hadolint ignore=DL3059
RUN mkdir -p /var/lib/nfs

# Copy root filesystem
COPY --link rootfs /

LABEL \
    org.opencontainers.image.title="Home Assistant app: NFS Server" \
    org.opencontainers.image.description="Network File System (NFS) server for Home Assistant." \
    org.opencontainers.image.source="https://github.com/salim-b/home-assistant-apps-salim" \
    org.opencontainers.image.licenses="Apache License 2.0"

# Health check: rpc.nfsd only configures the in-kernel server and then exits, hence probe the kernel's NFS
# listener on TCP port 2049 (rootfs/usr/bin/nfsd-healthcheck; nfs-server/KNOWLEDGE.md §"`rpc.nfsd` is not a daemon").
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["/usr/bin/nfsd-healthcheck"]
