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

## Resolved

- Repo sweep + dev tooling review (2026-10-16) done: the CI "redundancy" check resolved as proper architecture
  (build-app.yaml is a reusable `workflow_call` workflow invoked by builder.yaml; fetch-depth and squash-merge caveats
  documented). The SSH-helper factoring had one consumer until deploy-registry arrived - the shared lib
  (.mise/tasks/lib/ssh-ha.sh) landed together with it, and lint.sh now runs shellcheck with `-x` (follows `source`
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
