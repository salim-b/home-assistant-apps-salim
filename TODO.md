# TODOs

Cross-app work items (tooling, CI, harnesses); app-specific items live in each app's `TODO.md`. Underlying technical
facts live in the repository-root `KNOWLEDGE.md`.

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
  `NEWLINE` + `LINE_PREFIX` inside). Until fixed, this repo keeps struck spans on a single line (see `AGENTS.md`, tool
  notes).

- Upstream: file an hk issue/PR against [jdx/hk](https://github.com/jdx/hk) — its shebang-based file typing (v2.7.0,
  `src/file_type.rs`) does not recognize `#!/usr/bin/with-contenv bashio` (the Home Assistant base image's interpreter
  for s6-overlay scripts): wrapper interpreter plus unknown `bashio` argument resolve to plain text, so hk's
  shellcheck/shfmt/shellharden builtins (types `sh`/`bash`) silently skip every app script. Desired: look through
  s6-overlay's `with-contenv` (and similar env-style wrappers) to the real interpreter and type `bashio` as shell — the
  file content is plain bash. Until then, `hk.pkl` re-declares each shell builtin's `match_any` with added glob
  selectors for the s6 script paths (see the `s6Globs` comment there); the glob additions can be dropped once this
  lands.

- Upstream: investigate whether [shellharden](https://github.com/anordal/shellharden) mangles `for` loops and file an
  issue if none exists (check for existing ones first). Verified with v4.3.2 (2026-10): `--transform`/`--replace` quotes
  command substitutions in the iterable — `for _ in $(seq 1 120)` becomes `for _ in "$(seq 1 120)"` — which kills word
  splitting and makes the loop run exactly once (shellcheck flags the result as SC2066, error severity); an unquoted
  substitution in a for iterable is the idiomatic splitting form and not flagged by shellcheck. Minimal repro is a
  4-line script; the workaround rule (brace expansion, `read -r -a`, `mapfile`) and the 9 repo sites rewritten
  accordingly are documented in `AGENTS.md`, tool notes. The same run also confirmed the cosmetic nit of `[ -n "$x" ]`
  being rewritten to `[ "$x" != "" ]`. If upstream is unresponsive, reconsider whether shellharden should stay a fix
  step here (vs check-only or dropped).

## Resolved

- Apk-pin release automation end-to-end (2026-10-18; design decided 2026-10-17): Renovate automerges pkgrel-only apk pin
  bumps once CI is green and the CI follow-ups fill the changelog and self-heal publishes - the automation is documented
  in the apk package version policy section of the repository-root `KNOWLEDGE.md` (chained apk rules in
  `.github/renovate.json`: patch -> automerge with rebase strategy, minor/major -> `needs-review` label,
  `platformAutomerge: false`; apk-bump.yaml: post-merge changelog job driven by the shared `apk-changelog` mise task +
  daily `@renovate rebase` nudge capped at 3 per PR once all Alpine arch indexes serve the new pin;
  publish-reconcile.yaml: daily GHCR version-tag check dispatching build-app.yaml - now `workflow_dispatch`-able - on a
  genuine miss). Verified locally: the changelog parser reproduces the PR #3 data (hd-idle `1.22-r7` -> `1.22-r8`, app
  0.1.7) and the templated dry-run entry is panache-stable; the publish-reconcile dry-run reports both apps' current
  version tags as published (zero dispatches); the nudge dry-run is a no-op and its Dockerfile-pin/APKINDEX parse logic
  passes function tests against live Alpine v3.24 data. The build-app workflow_dispatch smoke test ran green on the
  branch (run 39098829377: prepare + both arch builds succeeded, the manifest publish skipped with publish=false - no
  registry writes). The first real Alpine repoint after landing validates the flow end to end (drift cron red ->
  Renovate PR -> green CI -> automerge -> Builder publish -> changelog commit) - do not fake events.

- Repo sweep + dev tooling review (2026-10-16) done: the CI "redundancy" check resolved as proper architecture
  (build-app.yaml is a reusable `workflow_call` workflow invoked by builder.yaml; fetch-depth and squash-merge caveats
  documented). The SSH-helper factoring had one consumer until deploy-registry arrived - the shared lib
  (.mise/tasks/lib/ssh-ha.sh) landed together with it, and linting now runs shellcheck with `-x` (follows `source`
  lines; without it the sourced helper produced SC1091 failures). nfs-server staleness pass: s6 ordering already correct
  (`dependencies.d/base` on every service); its comment-slimming pass is planned in nfs-server/TODO.md. New task
  `deploy-registry` shipped (see its header for the spec; config migration is opt-in with schema-key filtering). The lab
  boot marker (`legacy-services successfully started`) remains valid under the new s6 ordering. Hygiene and cross-app
  conventions checked clean. Follow-up (2026-10-16): both deploy tasks now take `--config migrate|reset` (mise usage
  `choices`-typed). reset wipes the target install's options (the repo config.yaml defaults are POSTed, not `{}` - a
  fresh POST is schema-validated and rejected for required keys, device-verified), migrate is unchanged, and unset =
  discard is now the default on deploy-registry (the deliberate refusal is gone). Every option set that dies with an
  uninstall, a discard or a reset is backed up to a local file first (path printed). Shared HA-API helpers (options
  read/POST, schema keys incl. the array-form shape, filter, backup) live in `.mise/tasks/lib/ssh-ha.sh`.
