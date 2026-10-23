# TODOs

Cross-app work items (tooling, CI, harnesses); app-specific items live in each app's `TODO.md`. Underlying technical
facts live in the repository-root `KNOWLEDGE.md`; procedures in the skills under `.agents/skills/`.

## Tasks

- Upstream: file a formatter bug against [panache](https://github.com/jolars/panache) — its reflow is non-idempotent on
  a multi-line ~~strikethrough~~ inside a list item: the continuation line's indent grows by 2 spaces on every
  `panache format` run, so `format --check` never settles afterward — violating the formatter's documented idempotency
  golden rule ([formatting guide](https://panache.bz/guide/formatting.html)).

  Reproducer (panache 3.16.0, verified 2026-10; default settings suffice, the wrap just lands elsewhere at other
  line-widths):

  ```markdown
  - ~~Create upstream PR in HA to render app configuration labels in the UI as Markdown blocks instead of the current
    single-line plain text.~~
  ```

  Findings to include in the issue: every run re-indents the continuation +2 (4 → 6 → 8 …); top-level multi-line
  strikethroughs are stable, as are bold/strong and code spans wrapping inside list items — only strikethrough in a list
  item is affected; `-o extensions.strikethrough=false` does not help (the CST still yields a `STRIKEOUT` node with
  `NEWLINE` + `LINE_PREFIX` inside). Until fixed, this repo keeps struck spans on a single line (skill
  `ha-app-markdown`).

- Upstream: file an hk issue/PR against [jdx/hk](https://github.com/jdx/hk) — its shebang-based file typing (v2.7.0,
  `src/file_type.rs`) does not recognize `#!/usr/bin/with-contenv bashio` (the Home Assistant base image's interpreter
  for s6-overlay scripts): wrapper interpreter plus unknown `bashio` argument resolve to plain text, so hk's
  shellcheck/shfmt/shellharden builtins (types `sh`/`bash`) silently skip every app script. Desired: look through
  s6-overlay's `with-contenv` (and similar env-style wrappers) to the real interpreter and type `bashio` as shell — the
  file content is plain bash. Until then, `hk.pkl` re-declares each shell builtin's `match_any` with added glob
  selectors for the s6 script paths (see the `s6Globs` comment there); the glob additions can be dropped once this
  lands.

- Upstream: file an hk issue against [jdx/hk](https://github.com/jdx/hk) (likely co-filed with
  [owenlamont/ryl](https://github.com/owenlamont/ryl)) — the `ryl` builtin's fix-mode wiring silently passes files with
  unfixable violations. hk's fix mode runs `check_diff` first and skips the fixer when it exits 0; ryl 0.26.0's `--diff`
  exit code reflects only patch presence: it exits 0 whenever nothing is fixable — including files carrying unfixable
  warnings or errors (probed 2026-10-20: `ryl check --diff` on a duplicate-key error file exits 0, and `--strict` does
  not change `--diff` exit codes; a fixable brace-spacing file prints the patch and exits 1). With the builtin as
  shipped (hk v2.7.0 `pkl/builtins/ryl.pkl`: `check_diff = ryl check --diff {{files}}`, `check_after_diff = true`),
  every pre-commit run (fix mode) passes files that `hk check --all` fails — the `check_after_diff` recheck never fires
  because no diff was applied. hk's own builtin test misses this: `testMaker.fixFail` exercises the fix command
  directly, not the check_diff-first flow the hook actually takes. Investigate which side should own the fix: ryl
  exiting non-zero from `--diff` when diagnostics exist without fixes, or hk not treating `check_diff` exit 0 as "clean"
  for partial fixers (e.g. re-running `check` when the fixer is skipped). Until then, this repo's `hk.pkl` clears
  `check_diff`/`check_after_diff`/`check_list_files` on the ryl step and puts `--strict` on both `check` and `fix` (the
  fix run is self-verifying: exit 0 only when nothing remains to fix or flag); the overrides can be dropped once this
  lands.

- Upstream: file an hk PR against [jdx/hk](https://github.com/jdx/hk) adding a `panache` builtin
  (`pkl/builtins/panache.pkl`): [panache](https://github.com/jolars/panache) is the Markdown formatter this repo runs as
  a custom hk step (`check = panache format --check {{files}}`, `fix = panache format {{files}}` over
  `**/*.md`/`**/*.markdown`), installed via the aqua registry (`aqua:jolars/panache`), so a builtin would let repos drop
  the custom step the same way the rumdl/ryl builtins do. Design point to settle in the PR: hk passes explicit file
  paths, and panache bypasses its own config excludes for explicit paths (observed here — hence the `mdExcludes` for
  `AI_POLICY.md` and `**/LICENSE.md` in `hk.pkl`); decide whether the builtin filters such files itself, documents the
  interaction, or waits for panache to honor excludes on explicit paths (cf. the panache strikethrough idempotency entry
  above for the other known panache quirk).

- Upstream: investigate whether [shellharden](https://github.com/anordal/shellharden) mangles `for` loops and file an
  issue if none exists (check for existing ones first). Verified with v4.3.2 (2026-10): `--transform`/`--replace` quotes
  command substitutions in the iterable — `for _ in $(seq 1 120)` becomes `for _ in "$(seq 1 120)"` — which kills word
  splitting and makes the loop run exactly once (shellcheck flags the result as SC2066, error severity); an unquoted
  substitution in a for iterable is the idiomatic splitting form and not flagged by shellcheck. Minimal repro is a
  4-line script; the workaround rule (brace expansion, `read -r -a`, `mapfile`) and the 9 repo sites rewritten
  accordingly are documented in skill `ha-app-tooling`. The same run also confirmed the cosmetic nit of `[ -n "$x" ]`
  being rewritten to `[ "$x" != "" ]`. If upstream is unresponsive, reconsider whether shellharden should stay a fix
  step here (vs check-only or dropped).

- apk-pin checker: deduplicate the triplicated pin parser — the `pkg=version` regex plus the backslash-continuation
  state machine over `apk add` blocks exists three times (`.mise/tasks/validate.py`, and the changelog + nudge jobs of
  `.github/workflows/apk-bump.yaml`; the trigger is the literal substring `apk add` in a line) with no canary fixture
  locking their behavior together — and align the index/arch semantics: validate.py consults ONE repo index per arch
  (community preferred, main only as fetch fallback; hardcoded x86_64/aarch64, packages absent from the index are
  silently skipped) while apk-bump.yaml merges main+community (main wins) and derives arches from each app's
  `config.yaml` (facts: root `KNOWLEDGE.md` §"apk package version policy").

## hickory-dns (planned app)

A forwarding DNS server app wrapping the Alpine `hickory-dns` package: LAN-wide secure DNS on port 53
(`host_network: true` — the AdGuard Home/Pi-hole add-on precedent; the HAOS host itself binds nothing on 53),
user-configured upstream recursive resolvers over DoT/DoH/DoQ with local DNSSEC validation (root KSKs are embedded in
the upstream binary — `validate = true`, no anchor file), a private-network `allow_networks` ACL, and static hostname→IP
entries served from generated Primary zone files: there is no hosts-file store upstream (the server's store types are
file/in_memory/sqlite/forwarder/recursor/blocklist — `crates/server/src/store/mod.rs` at v0.26.3), so each entry becomes
a per-name leaf zone answered authoritatively before the `.` forward zone. Default upstreams: Quad9 DoT (9.9.9.9 and
149.112.112.112, SNI dns.quad9.net — pure IPs plus pinned SNI, so no boot-time resolution is needed). Items below move
into `hickory-dns/TODO.md` when the app is scaffolded.

- Scaffold the app on branch `agent-hickory-dns` per skill `ha-app-scaffolding`: config.yaml (`host_network: true`;
  options `upstreams` (URL list, scheme + host-or-IP\[:port\]\[#sni\], resolved to upstream `ip` + `server_name` pairs
  at config-generation time with a last-known-good cache in /data), `allow_networks`, `dnssec`, `static_entries`
  (list-of-objects hostname/IP pairs), `debug`), translations/en.yaml, Dockerfile with pinned `hickory-dns` +
  `hickory-dns-utils` (policy: root `KNOWLEDGE.md` §"apk package version policy"; development pin 0.26.1-r0 until the
  aports bump below lands, release gate at ≥ 0.26.3), rootfs s6 user-bundle service plus cont-init config generator
  (generated config `--validate`d at boot), apparmor.txt (`capability net_bind_service`;
  `network inet/inet6 stream/dgram`), DOCS.md (router setup, static-IP/no-DNS-loop warning, single port-53-binder note,
  IPv6 RA caveat), CHANGELOG.md, KNOWLEDGE.md, and a lab hook with DNS probes (skill `ha-app-lab-testing`).

- Upstream: file aports MRs bumping community/hickory-dns from 0.26.1 to 0.26.3 — master first, then the `[3.24]`
  backport (observed stable-branch practice) — and gate the first app release on 3.24-stable serving ≥ 0.26.3. Both
  `3.24-stable` and `master` sit at 0.26.1-r0 while the v0.26.2 security release alone fixed ~38 GHSA advisories
  (DNSSEC-validation bypasses among them — [release
  notes](https://github.com/hickory-dns/hickory-dns/releases/tag/v0.26.2)); apk updates are manual MRs (no bump bot
  exists; the qa-bot only labels), and the maintainer (msrd0) has shown no aports activity since 2026-06.

- Later: optional blocklists (deferred from v1.0): download user-configured list URLs via curl in cont-init into /data
  and generate a chained `[[zones.stores]] type = "blocklist"` store ahead of the forward store. Upstream constraints:
  plain domain lists and `0.0.0.0 <domain>` hosts-format lines only, local files read once at startup, no hot reload
  (upstream issue #3460 — restart the app to refresh), and non-address query types are sunk to the sinkhole A record
  (upstream TODO in blocklist.rs).

- Later: DoH3 (`h3://`) upstreams — the bin-level `h3-aws-lc-rs` feature exists only in unreleased code (PRs
  #3993/#3994, merged 2026-09-25, no tagged release carries it as of v0.26.3); once a tagged release ships it and the
  apk picks it up, accept `h3://` upstream URLs (the app's upstream-URL schema is designed to accept them from day one).
