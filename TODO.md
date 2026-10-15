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
