<!-- https://contributors.home-assistant.io/apps/guides/presentation/#changelog -->

# Changelog

## 0.1.0

- Initial release.
- DNS server (hickory-dns in forwarding-resolver mode): the app binds DNS port 53 in the host network namespace; the
  router advertises the HAOS device IP once and all LAN devices resolve through it.
- Encrypted upstream resolution (DoT, DoH, DoQ; plaintext udp/tcp for special cases) configured as structured
  per-resolver entries (protocol, host, IP, port, path), queried in configured order; hostname upstreams are resolved
  once at startup with a last-known-good cache in `/data`.
- DNSSEC validation on by default (root KSKs embedded in the hickory-dns binary; no anchor file).
- Client ACL (allowed networks, private ranges + loopback by default; empty list = serve everyone).
- Static entries: hosts.txt-style hostname-to-IP pairs served as authoritative leaf zones, winning over the forwarded
  public namespace.
- Boot-time configuration generation with fail-fast validation (`hickory-dns --validate` parses the generated config and
  loads every zone file before the daemon starts).
- Custom AppArmor profile (port-53 bind + privilege-drop capabilities, network mediation, enumerated file surface);
  daemon drops privileges to `nobody` right after binding port 53.
- hickory-dns apk packages pinned (0.26.1-r0): Alpine-side package updates become explicit app releases, guided by the
  CI drift check (see the repository-root `KNOWLEDGE.md` apk package version policy). The first release is gated on a
  3.24-stable APKINDEX serving >= 0.26.3 (hickory-dns/TODO.md).
