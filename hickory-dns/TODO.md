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

- **Expose the response-cache TTL clamps as app options**: the generator pins `positive_max_ttl` and `negative_max_ttl`
  (`ResolverOpts` - §"Generated named.toml") to 3600; replace them with two configurable options defaulting to
  `positive_max_ttl = 86400` (honor record authors' TTLs - equals the resolver's `MAX_TTL`, re-verify per apk bump) and
  `negative_max_ttl = 60` (bounded negative caching - a name that just starts resolving works within a minute). Covers:
  generator `OPTIONS_BLOCK` interpolation + value validation, config option/schema/translations, recording the
  per-option why in §"Generated named.toml" (currently only git history has it), regression-sandbox snapshot update,
  lab, version bump + CHANGELOG.
