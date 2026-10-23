# Home Assistant app: hickory-dns

LAN-wide DNS server: every LAN device resolves through this app, which forwards to encrypted upstream DNS
(DNS-over-TLS/HTTPS/QUIC) with DNSSEC validation.

![Supports aarch64 Architecture][aarch64-shield] ![Supports amd64 Architecture][amd64-shield]

## Features

- **Encrypted home DNS**: point the router's DHCP DNS at the Home Assistant device once - all LAN devices resolve
  through the app, and its upstream connections are encrypted (DoT, DoH, DoQ) instead of plaintext port-53 queries
  leaving the home.
- **DNSSEC validated by default**: upstream answers are checked against the root trust anchors (embedded in the
  hickory-dns binary); bogus answers are rejected.
- **Configurable upstream resolvers**: Quad9 by default (anycast, pure IPs with pinned TLS names); Cloudflare, AdGuard,
  Google etc. via one-URL-per-entry configuration.
- **Static entries**: hosts.txt-style hostname-to-IP answers served locally as authoritative zones - reach self-hosted
  services by name from every LAN device without touching public DNS.
- **Client ACL**: only queries from the configured networks are served (private ranges + loopback by default).
- **Hardened runtime**: custom [AppArmor](https://apparmor.net/) profile, privilege drop right after the port-53 bind,
  boot-time validation of the generated configuration with the real binary.

## Limitations

- **One port-53 binder per host**: the app joins the host network namespace and binds port 53 - it cannot run alongside
  another DNS app (AdGuard Home, Pi-hole) on the same device.
- **DoH3 (HTTP/3) upstreams are not available yet**: the packaged binary's h3 feature is not in any tagged upstream
  release; the app rejects `h3://` URLs until it lands (see `hickory-dns/TODO.md`).
- **No ad/blocklist support yet** (tracked in `hickory-dns/TODO.md`): the upstream blocklist store exists but the
  feature ships after the first release.

## Documentation

For usage, configuration and security notes, see the
[**Documentation**](/config/app/f8b2d53d_hickory-dns/documentation).

[aarch64-shield]: https://img.shields.io/badge/aarch64-yes-green.svg
[amd64-shield]: https://img.shields.io/badge/amd64-yes-green.svg
