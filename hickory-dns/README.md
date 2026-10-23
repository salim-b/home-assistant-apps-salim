# Home Assistant app: hickory-dns

Turn your Home Assistant instance into a secure DNS server that resolves via encrypted upstream DNS
(DNS-over-TLS/HTTPS/QUIC) with DNSSEC validation. Built on memory-safe [Hickory DNS](https://hickory-dns.org/#server).

![Supports aarch64 Architecture][aarch64-shield] ![Supports amd64 Architecture][amd64-shield]

## Features

- **Encrypted home DNS**: Simply point your home router's DHCP DNS at your Home Assistant device once and all LAN
  devices resolve through the app, with all outgoing DNS traffic being encrypted (DoT, DoH, DoQ) instead of plaintext
  port-53 queries leaving the home.
- **DNSSEC validated by default**: Upstream answers are checked against the root trust anchors (embedded in the
  hickory-dns binary); bogus answers are rejected.
- **Configurable upstream resolvers**: Quad9 by default (anycast, pure IPs with pinned TLS names); Cloudflare, AdGuard,
  Google etc. via structured per-resolver entries (protocol, host, IP, port).
- **Static entries**: `hosts.txt`-style hostname-to-IP answers served locally as authoritative zones – reach self-hosted
  services by name from every LAN device without touching public DNS.
- **Client ACL**: Only queries from the configured networks are served (private ranges + loopback by default).
- **Hardened runtime**: Ships a custom [AppArmor](https://apparmor.net/) profile that restricts capabilities to what the
  server needs. Initially required privileges are dropped right after the port-53 bind.

## Limitations

- **One port-53 binder per host**: The app joins the host network namespace and binds port 53 – it cannot run alongside
  another DNS app (e.g. [AdGuard Home](/config/app/a0d7b954_adguard/info) or [Dnsmasq](/config/app/core_dnsmasq/info))
  on the same device.
- **DoH3 (HTTP/3) upstreams are not available yet**: the packaged binary's h3 feature is not in any tagged upstream
  release; the app rejects DoH3 upstreams until it lands (see `hickory-dns/TODO.md`).
- **No ad/blocklist support yet** (tracked in `hickory-dns/TODO.md`): the upstream blocklist store exists but the
  feature ships after the first release.

## Documentation

For usage, configuration and security notes, see the
[**Documentation**](/config/app/f8b2d53d_hickory-dns/documentation).

[aarch64-shield]: https://img.shields.io/badge/aarch64-yes-green.svg
[amd64-shield]: https://img.shields.io/badge/amd64-yes-green.svg
