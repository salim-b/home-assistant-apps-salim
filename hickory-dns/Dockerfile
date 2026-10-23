ARG BUILD_FROM=ghcr.io/home-assistant/base:3.24
FROM ${BUILD_FROM}

# Pinned apk packages (repository-root KNOWLEDGE.md §"apk package version policy"): the generated config encodes
# the hickory-dns binary's interface (named.toml schema + CLI), so package updates become deliberate app releases
# guided by the CI drift check. Development pin 0.26.1-r0 (current on 3.24-stable; identical config plumbing) -
# hickory-dns/TODO.md gates the first release on a 3.24-stable APKINDEX serving >= 0.26.3 (v0.26.2 fixed ~38 GHSA
# advisories). ca-certificates-bundle: system trust store read by hickory-dns's rustls-platform-verifier when
# connecting to DoT/DoH/DoQ upstreams (certificate data package, floating).
RUN apk add --no-cache \
    hickory-dns=0.26.1-r0 \
    hickory-dns-utils=0.26.1-r0 \
    ca-certificates-bundle

COPY --link rootfs /

LABEL \
    org.opencontainers.image.title="Home Assistant app: hickory-dns" \
    org.opencontainers.image.description="DNS server resolving via encrypted upstream DNS (DoT/DoH/DoQ) with DNSSEC validation." \
    org.opencontainers.image.source="https://github.com/salim-b/home-assistant-apps-salim" \
    org.opencontainers.image.licenses="Apache License 2.0"

# Probe with a real DNS query for the authoritative localhost zone over UDP to 127.0.0.1:53 (hickory-dns-utils'
# `dns` CLI). Exercises the daemon end-to-end without depending on upstream reachability - a dead upstream must
# not mark a healthy local DNS server unhealthy. Timeout > the probe's client-side query timeout.
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD ["/usr/bin/hickory-dns-healthcheck"]
