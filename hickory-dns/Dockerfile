ARG BUILD_FROM=ghcr.io/home-assistant/base:3.24
FROM ${BUILD_FROM}

# apk pins: repository-root KNOWLEDGE.md §"apk package version policy" (updates become deliberate app releases);
# the first-release gate on >= 0.26.3: hickory-dns/TODO.md (facts: hickory-dns/KNOWLEDGE.md §"apk package pins
# and CA trust"). ca-certificates-bundle: the rustls-platform-verifier trust store (floating). setpriv
# (util-linux, floats): the never-root launcher needs its uid options - the busybox applet has none; see
# hickory-dns/KNOWLEDGE.md §"Port 53 binding and privileges".
RUN apk add --no-cache \
    hickory-dns=0.26.1-r0 \
    hickory-dns-utils=0.26.1-r0 \
    ca-certificates-bundle \
    setpriv

COPY --link rootfs /

LABEL \
    org.opencontainers.image.title="Home Assistant app: hickory-dns" \
    org.opencontainers.image.description="DNS server resolving via encrypted upstream DNS (DoT/DoH/DoQ) with DNSSEC validation." \
    org.opencontainers.image.source="https://github.com/salim-b/home-assistant-apps-salim" \
    org.opencontainers.image.licenses="Apache License 2.0"

# Real-query probe (socket + catalog + response, no upstream dependency): hickory-dns/KNOWLEDGE.md §"Healthcheck".
# Timeout > the probe's client-side query timeout.
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD ["/usr/bin/hickory-dns-healthcheck"]
