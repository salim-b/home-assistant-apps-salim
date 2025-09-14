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
