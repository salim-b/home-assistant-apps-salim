<!-- https://contributors.home-assistant.io/apps/guides/presentation/#changelog -->

# Changelog

## 0.3.1

- Updated the bundled hickory-dns from 0.26.1-r0 to 0.26.3-r0 ([upstream release
  notes](https://github.com/hickory-dns/hickory-dns/releases/tag/v0.26.3)).

## 0.3.0

- Private-use reverse zones (RFC 6303) are now answered locally: PTR lookups for RFC 1918/ULA/link-local addresses
  (`10.in-addr.arpa`, `16.172.in-addr.arpa` through `31.172.in-addr.arpa`, `168.192.in-addr.arpa`, `d.f.ip6.arpa`,
  `8.e.f.ip6.arpa`) never leave the device. Public resolvers answer private-namespace queries with synthesized,
  proof-less NXDOMAINs, which DNSSEC validation must reject as Bogus – the source of the "response does not contain NSEC
  or NSEC3 records" warnings and the SERVFAILs for LAN reverse lookups.
- Static entries now also answer the matching PTR lookup: an entry for `nas.lan` -> `192.168.1.10` serves reverse
  lookups of `192.168.1.10` with `nas.lan` from its own reverse zone. Entries sharing one address share one reverse zone
  with one PTR per name.
- Internals: the app's scripts were reformatted and quoting-hardened by the repository's full shell gate – no functional
  changes.

## 0.2.0

- The default upstream resolvers now talk DNS-over-QUIC (DoQ, UDP port 853) instead of DoT: QUIC multiplexes queries
  without TCP head-of-line blocking and opens the encrypted connection in a single round trip, and Quad9 serves DoQ on
  all of its variants. Existing installs keep their saved configuration – switch the upstreams' protocol to `quic` in
  the app options to adopt the new default.

## 0.1.1

- Renamed the app to "Hickory DNS" (display name only – the `hickory-dns` slug, install URL and image names stay the
  same).

## 0.1.0

- Initial release.
- DNS server in forwarding-resolver mode: point the router's DHCP DNS at the Home Assistant device once and all LAN
  devices resolve through it (DNS port 53 on the host network).
- Encrypted upstream resolution (DoT, DoH, DoQ – plaintext upstreams are rejected), configured as structured
  per-resolver entries (protocol, host, IP, port, path) queried in the configured order. Hostname upstreams are resolved
  once at startup – time-bounded so a slow system resolver cannot stall the boot, with a last-known-good address cache
  as fallback.
- DNSSEC validation on by default; bogus answers are rejected.
- Client ACL (allowed networks): private LAN ranges + loopback by default; an empty list serves everyone; loopback is
  always served so the app's own health probe works.
- Quiet logs: the health probe queries the zone's SOA record instead of an A record – positive answers from the unsigned
  local zones make the daemon log a warning per query, the SOA query is answered without one.
- Static entries: hosts.txt-style hostname-to-IP pairs served as authoritative local zones, winning over public records.
- Boot-time configuration generation with fail-fast validation: the generated config is parsed and every zone file is
  loaded by the real binary before the daemon starts.
- Custom AppArmor profile; the daemon never runs as root – it starts as `nobody` holding only the capability the port-53
  bind requires.
- hickory-dns apk packages pinned (0.26.1-r0): Alpine-side package updates become explicit app releases guided by the CI
  drift check.
