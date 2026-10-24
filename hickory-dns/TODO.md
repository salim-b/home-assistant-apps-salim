# TODOs

Open work items only (resolved items live in git history). Underlying technical facts live in `KNOWLEDGE.md`.

## Tasks

- **Alpine aports bump MRs (blocking the first release)**: `community/hickory-dns` is at 0.26.1-r0 on 3.24-stable and
  master (identical), missing v0.26.2 which fixed ~38 GHSA advisories (DNSSEC validation bypasses, DoS amplification,
  UDP spoofing) plus v0.26.3 regressions fixes. Submit both:
  1. master: fork gitlab.alpinelinux.org/alpine/aports, branch, bump `pkgver=0.26.3` with `pkgrel=0` (pkgrel resets on
     pkgver bumps; NO DCO sign-off needed), update sha512sums, run `apkbuild-lint` + `abuild -r` (the build needs
     `cargo cargo-auditable clang-dev cmake samurai`; consider a docker-based abuild), commit
     `community/hickory-dns: upgrade to 0.26.3`, open the MR.
  2. `[3.24]-stable`: cherry-pick as `[3.24] community/hickory-dns: upgrade to 0.26.3` (the established backport
     naming), frame the MR with the GHSA list. No bump bot exists for aports (aports-qa-bot only labels/comments) and
     the maintainer (msrd0) has been inactive since 2026-06; an "Upgrade Request" issue on the aports tracker is the
     nudge if the MRs stall. **Gate the first app release on a 3.24-stable APKINDEX serving >= 0.26.3** (the Dockerfile
     pin must be bumped in the same app release: pin + config.yaml version + changelog, per the repository-root
     `KNOWLEDGE.md` apk package version policy).

- **Device verification** (only on explicit user request; the lab has NO AppArmor enforcement, so capability denials are
  device-only findings): verify the never-root launcher under AppArmor enforcement - the daemon runs as nobody (65534)
  with exactly the ambient CAP_NET_BIND_SERVICE (the lab asserts those credentials), the launcher's
  setgid/setuid/setpcap use (setpriv) is not denied, and no error/denial lines appear in the app log. Re-check after the
  apk bump (hickory-dns/KNOWLEDGE.md §"Port 53 binding and privileges").

- **Blocklist support (deferred)**: upstream has a `blocklist` store (compiled into the apk: the `_cargo_opts_bin`
  feature list includes `blocklist`). Design: download list URLs in cont-init into `/data` (curl), chain a
  `[[zones.stores]] type = "blocklist"` ahead of the forward store. Ground truth at v0.26.3: plain domain lists and
  `0.0.0.0 <domain>` hosts lines only (no other hosts-file flavors), local files read once at startup with NO hot reload
  (upstream issue #3460 - restart the app to refresh), non-address query types sink to a forged sinkhole A/AAAA
  (sinkhole_ipv4 defaults 0.0.0.0), and absolute file paths are allowed since 0.26.2 (PR #3864).

- **DoH3 upstreams (deferred)**: the bin `h3-aws-lc-rs`/`h3-ring` features are merged upstream (PRs #3993/#3994,
  2026-09-25) but NOT in any tagged release, so no apk can ship them yet. The generator already rejects `protocol = h3`
  with a pointed error; revisit when a tagged release + the apk carry the bin h3 features (the H3 protocol table also
  needs `path`, like https - `crates/resolver/src/config.rs` `ProtocolConfig::H3`).

- **SPKI pinning for configured upstreams**: ground truth at v0.26.3 - there is NO config surface for it. Upstream
  connection config is `ip` + protocol tables (`server_name`/`path` only, `deny_unknown_fields`,
  `crates/resolver/src/config.rs` `ProtocolConfig`), TLS verification is fixed to rustls-platform-verifier /
  webpki-roots (`crates/net/src/tls.rs` `client_config()`), and the only SPKI-adjacent code is TLSA record parsing
  (`crates/proto/src/rr/rdata/tlsa.rs`), not wired into upstream validation. This is a genuine gap for the app's threat
  model (a mis-issued CA could impersonate `dns.quad9.net`). Track/file an upstream feature request; revisit when a
  tagged release grows a pinning knob (not patchable into the apk binary). If/when one exists, expose an app option.
