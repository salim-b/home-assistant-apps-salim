---
name: ha-app-markdown
description: Markdown formatting conventions for this repository — panache owns all formatting, rumdl is the semantic
  second linter, and specific constructs break the toolchain. Use when writing or editing any Markdown file here.
---

# Markdown conventions

## Formatting ownership

- panache (`panache.toml`) owns ALL formatting: `mise run fmt` reflows prose to the 120-char width. Never hand-wrap
  prose — write naturally and let `fmt` shape it.
- The lint gate runs `panache format --check` and `panache lint` over tracked `.md` files (excluding `AI_POLICY.md`,
  which is upstream-verbatim, and `**/LICENSE.md`). The lint adds semantic checks (references, heading hierarchy, …).

## rumdl

- Second linter (`.rumdl.toml`, markdownlint-rules-rich); its own reflow is disabled (its fill state disagrees with
  panache's), so MD013 is a pure width check: code blocks exempt, lines whose only overrun is an unbreakable code span
  forgiven.
- rumdl never rewrites files: its fix allow-list is pinned to an inert `all` sentinel (behavioral canary in
  validate.py). Formatting fixes go through panache (`mise run fmt`); non-format rumdl findings are fixed by hand.

## Constructs that break the toolchain — write around them

- Multi-line ~~strikethrough~~ inside a list item: panache's reflow is non-idempotent on it (the continuation line's
  indent grows every run). Keep struck spans on a single line — shorten the wording; MD013 caps the width at 120.
  (Upstream bug: root `TODO.md`.)
- Do not let prose wrap so that a line starts with an ordered-list marker (`4)`, `2026.` — a parenthetical ending in
  digits does this at wrap boundaries): CommonMark renders such a line as prose, panache formats it as a nested list,
  and the two disagree.
