<!-- https://contributors.home-assistant.io/apps/guides/presentation/#changelog -->

# Changelog

## 0.1.1

- Renamed the app to "Hickory DNS" (display name only - the `hickory-dns` slug, install URL and image names stay the
  same).

## 0.1.0

- Initial release.
- DNS server in forwarding-resolver mode: point the router's DHCP DNS at the Home Assistant device once and all LAN
  devices resolve through it (DNS port 53 on the host network).
- Encrypted upstream resolution (DoT, DoH, DoQ - plaintext upstreams are rejected), configured as structured
  per-resolver entries (protocol, host, IP, port, path) queried in the configured order. Hostname upstreams are resolved
  once at startup - time-bounded so a slow system resolver cannot stall the boot, with a last-known-good address cache
  as fallback.
- DNSSEC validation on by default; bogus answers are rejected.
- Client ACL (allowed networks): private LAN ranges + loopback by default; an empty list serves everyone; loopback is
  always served so the app's own health probe works.
- Quiet logs: the health probe queries the zone's SOA record instead of an A record - positive answers from the unsigned
  local zones make the daemon log a warning per query, the SOA query is answered without one.
- Static entries: hosts.txt-style hostname-to-IP pairs served as authoritative local zones, winning over public records.
- Boot-time configuration generation with fail-fast validation: the generated config is parsed and every zone file is
  loaded by the real binary before the daemon starts.
- Custom AppArmor profile; the daemon never runs as root - it starts as `nobody` holding only the capability the port-53
  bind requires.
- hickory-dns apk packages pinned (0.26.1-r0): Alpine-side package updates become explicit app releases guided by the CI
  drift check.
