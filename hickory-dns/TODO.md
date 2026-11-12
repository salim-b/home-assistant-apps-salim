# TODOs

Open work items only (resolved items live in git history). Underlying technical facts live in `KNOWLEDGE.md`, runtime
procedures in the skill `hickory-dns-runtime`.

## Tasks

- **Upstream DNSSEC validator false-Bogus on real-world response shapes**: with `dnssec` enabled the daemon SERVFAILs
  names that resolve fine everywhere else – two live repros, both reproduced with the pinned 0.26.1 apk against
  Cloudflare and Quad9 DoT upstreams and verified identical on a v0.26.3 source build: `public-dns.info` (unsigned
  apex-CNAME zone – the zone-cut search's NS query comes back answered with a CNAME, the walk lands in the signed parent
  zone and the unsigned CNAME is judged Bogus; [#4027](https://github.com/hickory-dns/hickory-dns/issues/4027),
  [#4063](https://github.com/hickory-dns/hickory-dns/issues/4063)) and `wiki.mint-system.ch` (wildcard-expanded CNAME in
  a signed NSEC zone – the recursor attaches only the wildcard's NSEC and the whole answer is rejected, CD=1 does not
  help; [#4047](https://github.com/hickory-dns/hickory-dns/issues/4047),
  [#3888](https://github.com/hickory-dns/hickory-dns/issues/3888)). No released version fixes these (0.26.3 included) -
  so wait for an upstream release that carries them (interim for affected sites: browser DoH, or the `dnssec` option
  off).

- Once hickory-dns 0.26.4+ is released shipping <https://github.com/hickory-dns/hickory-dns/pull/4128>, query an `A`
  instead of `SOA` record in `hickory-dns-healthcheck`.

- Re-run the live test on a device against the current pin (0.26.3-r0): the launcher's capability path was
  device-verified on daemon 0.26.1 only (facts: `KNOWLEDGE.md` §"Port 53 binding and privileges").

- **Blocklist support (deferred)**: upstream ground truth and the design sketch: `KNOWLEDGE.md` §"Deferred feature
  ground truth (upstream gaps)".

- **DoH3 upstreams (deferred)**: blocked on a tagged upstream release plus the apk carrying the bin h3 features
  (`KNOWLEDGE.md` §"Deferred feature ground truth (upstream gaps)"). The generator already rejects `protocol = h3` with
  a pointed error – revisit when that unblocks.

- **SPKI pinning for configured upstreams (deferred)**: no upstream config surface exists (`KNOWLEDGE.md` §"Deferred
  feature ground truth (upstream gaps)"). File the upstream feature request; revisit when a tagged release grows a
  pinning knob, then expose an app option.

- **Expose the response-cache TTL clamps as app options**: the generator pins `positive_max_ttl` and `negative_max_ttl`
  (`ResolverOpts` – §"Generated named.toml") to 3600; replace them with two configurable options defaulting to
  `positive_max_ttl = 86400` (honor record authors' TTLs – equals the resolver's `MAX_TTL`, re-verify per apk bump) and
  `negative_max_ttl = 60` (bounded negative caching – a name that just starts resolving works within a minute). Covers:
  generator `OPTIONS_BLOCK` interpolation + value validation, config option/schema/translations, recording the
  per-option why in §"Generated named.toml" (currently only git history has it), regression-sandbox snapshot update,
  lab, version bump + CHANGELOG.

- **Expose the response-cache size as an app option**: the generator pins `cache_size` (`ResolverOpts` – §"Generated
  named.toml") to 8192 (the upstream default); replace the pin with an optional configurable option defaulting to 8192
  (optional options stay hidden in the UI until the user toggles "Show unused optional configuration options", so the
  default path is unchanged). The value is an entry count, NOT bytes – validation: integer with sane lower/upper bounds.
  Covers: generator `OPTIONS_BLOCK` interpolation + validation, config option/schema/translations, recording the
  per-option why in §"Generated named.toml", regression-sandbox snapshot update, lab, version bump + CHANGELOG.

- **Expose `server_ordering_strategy` as an app option (with a derived `num_concurrent_reqs`)**: the generator pins
  `server_ordering_strategy = "UserProvidedOrder"` and `num_concurrent_reqs = 1` (`ResolverOpts` – §"Generated
  named.toml"); expose the strategy as a select (`UserProvidedOrder` default, `QueryStatistics`, `RoundRobin` – the
  generated TOML carries the Rust variant names verbatim, snake_case is rejected by the daemon) and derive
  `num_concurrent_reqs` from the strategy automatically: `1` for the default `UserProvidedOrder` (serial failover – the
  upstream option order stays the priority), `2` or more for `QueryStatistics` and `RoundRobin` (parallel fan-out; exact
  value TBD, e.g. the number of configured upstreams). Covers: generator emission + derivation + validation, config
  option/schema/translations, recording the per-option why in §"Generated named.toml", regression-sandbox snapshot
  update, lab, version bump + CHANGELOG.

- **Expose `max_active_requests` as an optional app option**: the cap on in-flight queries per multiplexed upstream
  connection (`ResolverOpts`, upstream default 32) currently applies as the silent upstream default; replace the silence
  with an optional configurable option defaulting to 32 (optional options stay hidden in the UI until the user toggles
  "Show unused optional configuration options", so the default path is unchanged). The value bounds concurrent queries
  per DoT/DoQ/DoH connection – validation: integer with sane lower/upper bounds. Covers: generator `OPTIONS_BLOCK`
  interpolation + validation, config option/schema/translations, recording the per-option why in §"Generated
  named.toml", regression-sandbox snapshot update, lab, version bump + CHANGELOG.

- **Rebind protection via `deny_answers` (opt-out, enabled by default)**: strip upstream answers whose addresses fall
  into private/reserved networks (DNS-rebinding defense) – the filter applies to forwarded answers only; local zones
  (`static_entries`, shipped default zones) bypass it, so the two compose cleanly. Exact shape TBD, two avenues: either
  a CIDR list reusing the `allow_networks` machinery (validation, loopback-append precedent) or a simpler bool that
  emits `deny_answers = [RFC1918, ULA, loopback, link-local]`. Enabled by default is a behavior change for existing
  installs – document it prominently and pick the version-bump level accordingly. Covers: generator emission +
  validation, config option/schema/translations, §"Generated named.toml" why, regression-sandbox snapshot update, lab
  (including a private-address upstream answer repro), version bump + CHANGELOG.

- **Per-entry TTL for static entries**: static leaf zones are hardcoded to `$TTL 300` (§"Static entries (no hosts-file
  store upstream)"); expose an optional `ttl` field per `static_entries` entry (default 300), emitted into the leaf
  zone's `$TTL` directive and validated (0 is legal per RFC 1035 – clients then don't cache). Settle in design: whether
  the SOA minimum (the leaf zones' negative TTL, currently 300) follows the entry TTL, and which entry's TTL the shared
  reverse zone gets when several entries share one address. Covers: config option/schema/translations, generator
  emission + validation, §"Static entries (no hosts-file store upstream)" facts, regression-sandbox snapshot update,
  lab, version bump + CHANGELOG.

- **Investigate replacing `host_network: true` with published `53/udp`+`53/tcp` ports (needs further investigation)**: a
  host-networked `0.0.0.0:53` listener answers container-originated queries with replies sourced from the route back to
  the client (the bridge gateway IP, not the queried device IP) – resolvers discard source-mismatched UDP replies, so
  docker containers cannot resolve through the app (this broke on-device app builds on the deployment device,
  2026-11-12: default-bridge build RUN steps copy the host's resolv.conf verbatim, apk cannot fetch the Alpine package
  index; CoreDNS only keeps working via its DoT fallback). Published ports get conntrack reply rewriting instead: LAN
  clients keep their source IPs (the reason host_network was chosen – `KNOWLEDGE.md` §"Port 53 binding and privileges"),
  while container/hairpin clients appear as gateway IPs (covered by the default `allow_networks` ACL's `172.16.0.0/12`)
  – fixing containers *and* CoreDNS everywhere. Migration needs care: re-verify the ACL/privilege story under DNAT and
  the bootstrap ordering (the app's own on-device build hits the same DNS bug until the device's DNS path is fixed; see
  the deploy:local pre-flight item in the root `TODO.md`).
