# syntax=docker/dockerfile:1

# https://developers.home-assistant.io/docs/apps/configuration#app-dockerfile
ARG BUILD_FROM
FROM $BUILD_FROM

# Execute during the build of the image
ARG TEMPIO_VERSION BUILD_ARCH
RUN curl -sSLf -o /usr/bin/tempio \
  "https://github.com/home-assistant/tempio/releases/download/${TEMPIO_VERSION}/tempio_${BUILD_ARCH}"

# Install requirements for app
RUN apk add --no-cache \
  nfs-utils

# Create necessary system directories
RUN mkdir -p /var/lib/nfs

# Copy root filesystem
COPY --link rootfs /

# Health check: rpc.nfsd only starts the NFS server in the kernel and then
# exits, hence probe the kernel's NFS listener on TCP port 2049 (see
# rootfs/usr/bin/nfsd-healthcheck).
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["/usr/bin/nfsd-healthcheck"]
