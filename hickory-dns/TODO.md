# TODOs

Open work items only (resolved items live in git history). Underlying technical facts live in `KNOWLEDGE.md`, runtime
procedures in the skill `hickory-dns-runtime`.

## Tasks

- **Alpine aports bump MRs (blocking the first release)**: `community/hickory-dns` is at 0.26.1-r0 on 3.24-stable and
  master (identical) - facts: `KNOWLEDGE.md` §"apk package pins and CA trust". Submit both:
  1. master: fork gitlab.alpinelinux.org/alpine/aports, branch, bump `pkgver=0.26.3` with `pkgrel=0` (pkgrel resets on
     pkgver bumps; NO DCO sign-off needed), update sha512sums, run `apkbuild-lint` + `abuild -r` (the build needs
     `cargo cargo-auditable clang-dev cmake samurai`; consider a docker-based abuild), commit
     `community/hickory-dns: upgrade to 0.26.3`, open the MR.
  2. `[3.24]-stable`: cherry-pick as `[3.24] community/hickory-dns: upgrade to 0.26.3` (the established backport
     naming), frame the MR with the GHSA list. No bump bot exists for aports (aports-qa-bot only labels/comments) and
     the maintainer (msrd0) has been inactive since 2026-06; an "Upgrade Request" issue on the aports tracker is the
     nudge if the MRs stall. **Gate the first app release on a 3.24-stable APKINDEX serving >= 0.26.3** (the Dockerfile
     pin must be bumped in the same app release: pin + config.yaml version + changelog, per the repository-root
     `KNOWLEDGE.md` apk package version policy). When the bumped daemon lands on the device, re-run the device
     verification: `mise run test:live hickory-dns <host> --replace --test-options` (never-root launcher path,
     device-verified for 0.26.1 on 2026-10-24 - `KNOWLEDGE.md` §"Port 53 binding and privileges").

- **Upstream issue for the `unexpected lookup skip` WARN** (small, not release-blocking): every positive answer from an
  unsigned authoritative zone (localhost, the static leaf zones) makes the 0.26.x daemon log
  `WARN hickory_server::zone_handler::catalog: unexpected lookup skip for request` - the catalog's positive-answer
  branch warns its no-NSEC-proof arm although that skip is the normal path (RFC 4035 §3.1.3 requires NSEC proofs only in
  the four negative cases). Verified upstream 2026-10-24: introduced in the 0.26.0 cycle (e7fed0e), present in
  0.26.0/0.26.1/0.26.3 and main (c6b2e6d); no duplicate on the tracker; standalone repro confirmed with the packaged
  binary + upstream's own localhost example zone (A warns, SOA/MX silent). File against hickory-dns/hickory-dns per
  their `bug_report.md` template (suggested fix: drop that warn to debug); mechanism + matrix: `KNOWLEDGE.md`
  §"Healthcheck" (the app healthcheck probes the zone SOA until this is fixed upstream).

- **Blocklist support (deferred)**: upstream ground truth and the design sketch: `KNOWLEDGE.md` §"Deferred feature
  ground truth (upstream gaps)". Pursue after the first release.

- **DoH3 upstreams (deferred)**: blocked on a tagged upstream release plus the apk carrying the bin h3 features
  (`KNOWLEDGE.md` §"Deferred feature ground truth (upstream gaps)"). The generator already rejects `protocol = h3` with
  a pointed error - revisit when that unblocks.

- **SPKI pinning for configured upstreams (deferred)**: no upstream config surface exists (`KNOWLEDGE.md` §"Deferred
  feature ground truth (upstream gaps)"). File the upstream feature request; revisit when a tagged release grows a
  pinning knob, then expose an app option.
