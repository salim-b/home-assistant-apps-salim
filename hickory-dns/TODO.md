# TODOs

Open work items only (resolved items live in git history). Underlying technical facts live in `KNOWLEDGE.md`, runtime
procedures in the skill `hickory-dns-runtime`.

## Tasks

- **Alpine aports bump MRs**: `community/hickory-dns` is currently still at 0.26.1-r0 on 3.24-stable and master
  (identical) - facts: `KNOWLEDGE.md` §"apk package pins and CA trust".

  Submitted two MRs upstream to bump to v0.26.3:
  - <https://gitlab.alpinelinux.org/alpine/aports/-/merge_requests/110680> (`master`)
  - <https://gitlab.alpinelinux.org/alpine/aports/-/merge_requests/110681> (`3.24-stable` backport)

  Once merged and the bumped apk reaches the index, our CI should pick up the update automatically.

- **Upstream DNSSEC validator false-Bogus on real-world response shapes**: with `dnssec` enabled the daemon SERVFAILs
  names that resolve fine everywhere else - two live repros, both reproduced with the pinned 0.26.1 apk against
  Cloudflare and Quad9 DoT upstreams and verified identical on a v0.26.3 source build: `public-dns.info` (unsigned
  apex-CNAME zone - the zone-cut search's NS query comes back answered with a CNAME, the walk lands in the signed parent
  zone and the unsigned CNAME is judged Bogus; [#4027](https://github.com/hickory-dns/hickory-dns/issues/4027),
  [#4063](https://github.com/hickory-dns/hickory-dns/issues/4063)) and `wiki.mint-system.ch` (wildcard-expanded CNAME in
  a signed NSEC zone - the recursor attaches only the wildcard's NSEC and the whole answer is rejected, CD=1 does not
  help; [#4047](https://github.com/hickory-dns/hickory-dns/issues/4047),
  [#3888](https://github.com/hickory-dns/hickory-dns/issues/3888)). No released version fixes these - the 0.26.3 bump
  MRs above do not include the fixes - so wait for an upstream release that carries them (interim for affected sites:
  browser DoH, or the `dnssec` option off).

- **Serve RFC 6303 private-use reverse zones locally**: the private-address sibling of the false-Bogus item above, but
  fixable entirely app-side — and only app-side: the validator's Bogus verdict is RFC-correct (RFC 4035 §5.4) and must
  not be relaxed, while hickory ships no RFC 6303 empty zones of its own (we already supply its 127/8, 0/8,
  255.255.255.255 and ::1 defaults for the same reason). The remedy — answering private reverse space locally — is a
  serving-side duty that is ours to implement. With `dnssec` on, PTR queries for LAN IPs (e.g.
  `248.1.168.192.in-addr.arpa`) are forwarded upstream, where Quad9 answers private-namespace queries with a synthesized
  bare NXDOMAIN - no SOA, no NSEC, EDE 29 "Synthesized" per their July 2026 "Keeping Private Namespace Queries Private"
  policy - although the name provably sits under the signed `192.in-addr.arpa` chain. The validator therefore rejects
  the unprovable negative as Bogus (the "response does not contain NSEC or NSEC3 records" warnings seen 2026-10-25) and
  SERVFAILs the client; later queries return clean NXDOMAINs once the chain-walk artifacts are cached, so the warnings
  come in bursts for never-seen names. Fix: serve the LAN reverse zone as a local empty authoritative zone - exactly
  like the shipped RFC 6303 defaults (127/8, 0/8, 255.255.255.255, ::1) - so such queries never leave the device and
  never reach validation. Open design: ship the full RFC 6303 private set as image-owned defaults (10.in-addr.arpa, the
  16 cuts 16-31.172.in-addr.arpa, 168.192.in-addr.arpa, d.f.ip6.arpa for ULA fd00::/8, 8.e.f.ip6.arpa for link-local)
  vs. a config option vs. deriving zones from `allow_networks`. Default-first matches the RFC and needs no config
  surface; the one caveat is that it would shadow real private PTRs if a user ever points `upstreams` at a LAN DNS
  server that serves them (public upstreams never do - they synthesize or refuse). Implementation: generator
  `DEFAULT_ZONE_FILES` plus new empty `default/*.zone` files; facts: `KNOWLEDGE.md` §"Generated named.toml"
  (default-zone mechanism + ordering) and §"Static entries (no hosts-file store upstream)" (static entries are
  forward-only, so no conflict).

- Once hickory-dns 0.26.4+ is released shipping <https://github.com/hickory-dns/hickory-dns/pull/4128>, query an `A`
  instead of `SOA` record in `hickory-dns-healthcheck`.

- **Blocklist support (deferred)**: upstream ground truth and the design sketch: `KNOWLEDGE.md` §"Deferred feature
  ground truth (upstream gaps)". Pursue after the first release.

- **DoH3 upstreams (deferred)**: blocked on a tagged upstream release plus the apk carrying the bin h3 features
  (`KNOWLEDGE.md` §"Deferred feature ground truth (upstream gaps)"). The generator already rejects `protocol = h3` with
  a pointed error - revisit when that unblocks.

- **SPKI pinning for configured upstreams (deferred)**: no upstream config surface exists (`KNOWLEDGE.md` §"Deferred
  feature ground truth (upstream gaps)"). File the upstream feature request; revisit when a tagged release grows a
  pinning knob, then expose an app option.
