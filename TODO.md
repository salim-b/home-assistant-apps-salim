# TODOs

Cross-app work items (tooling, CI, harnesses); app-specific items live in each app's `TODO.md`. Underlying technical
facts live in the repository-root `KNOWLEDGE.md`.

## Tasks

- Plan: repo sweep + dev tooling review (2026-10-16). Sequence:
  1. Baseline survey: inventory workflows, mise tasks, root docs, cross-app consistency surface.
  2. Repo sweep (findings first, then fixes): root `README.md`/`AGENTS.md`/`KNOWLEDGE.md` freshness (new tasks, new
     gotchas); nfs-server app staleness pass (its own TODO/KNOWLEDGE/CHANGELOG/config; cross-check it has the s6
     `dependencies.d/base` treatment and the comment-slimming standard); CI workflow redundancy check (build-app.yaml vs
     builder.yaml); hygiene (.gitignore/.editorconfig/devcontainer/renovate).
  3. Tooling review with value/complexity filter: factor the duplicated SSH helpers (`wait_supervisor`/`ha_retry` in
     deploy.sh and test/live.sh) into a sourced library; review lab.sh boot-wait markers under the new s6 ordering;
     review builder/version-guard interactions; collect further tweaks.
  4. New task `deploy-registry <app> <host>`: switch a device to the app's latest registry/store version.
     - Detects the local `/local_apps` copy (`local_<slug>`) and the repository-installed copy (hashed slug, derived
       deterministically: sha1 of the lowercased store repository URL, first 8 hex — supervisor
       `store/utils.py get_hash_from_repository`; verify against the pinned supervisor ref first).
     - Config migration is deliberate: if a previous install has options and no `--migrate-config` is given, abort
       (destructive default prevention); `--discard-config` skips migration explicitly.
     - Migration mechanics: read old options via `ha apps info --raw-json` → filter keys to the TARGET install's schema
       (stale keys fail a fresh options POST even though they are inert when already stored — device-verified
       2026-10-16) → uninstall local copy → install/update the store version → POST the filtered options (the
       supervisor-token curl pattern from test/live.sh) → ensure started, report version/state.
     - Edge cases to handle: app not in the device's store repo (clear error), registry/store version OLDER than the
       local copy (warn, proceed), post-install state=error (report + hint at the app log).
     - Docs: AGENTS.md command list, root README; CHANGELOG entries are per-app, tool-only change needs none.
  5. Final gates: `mise run check` + lab for any app-touching fallout; sweep items resolved; tooling notes landed.

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
