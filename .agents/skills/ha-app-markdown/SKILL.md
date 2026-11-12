---
name: ha-app-markdown
description: Markdown formatting conventions for this repository — panache owns all formatting, rumdl is the semantic
  second linter, and specific constructs break the toolchain. Use when writing or editing any Markdown file here.
---

# Markdown conventions

## Formatting ownership

- panache (`panache.toml`) owns ALL formatting: `mise run fmt` reflows prose to the 120-char width. Never hand-wrap
  prose — write naturally and let `fmt` shape it.
- The lint gate runs `panache format --check` and `panache lint` over tracked `.md` files (excluding `AI_POLICY.md` —
  the Open Home Foundation's policy text, kept verbatim for upstream syncs — and `**/LICENSE.md`, mirroring panache's
  default Markdown exclude). Explicit file paths bypass panache's config excludes, so hk's `mdExcludes` in `hk.pkl`
  repeats the exclusion for both step invocations. The lint adds semantic checks (references, heading hierarchy, …).

## rumdl

- Second linter (`.rumdl.toml`, markdownlint-rules-rich); its own reflow is disabled (its fill state disagrees with
  panache's), so MD013 is a pure width check: code blocks exempt, lines whose only overrun is an unbreakable code span
  forgiven. panache's reflow breaks around struck spans, never inside them (it leaves a too-long span overwide on its
  own line), and MD013 does not exempt struck spans the way it exempts code spans: keep struck spans within the
  120-column width.
- Inline HTML is allow-listed per element, not per file (MD033), see `.rumdl.toml` for the currently allowed HTML tags;
  every other tag fails the lint, READMEs included. Reach for Markdown constructs (links, images, emphasis, code spans)
  before raw HTML. In tables, `table_allowed_elements` replaces (does not union with) `allowed_elements` (rumdl 0.3.1).
- rumdl never rewrites files: its fix allow-list is pinned to an inert `all` sentinel (canonicalization-preserved,
  verified through rumdl 0.3.1; behavioral canary in `validate/apps.py`). Formatting fixes go through panache
  (`mise run fmt`); non-format rumdl findings are fixed by hand.

## Constructs that break the toolchain — write around them

- Do not let prose wrap so that a line starts with an ordered-list marker (`4)`, `2026.` — a parenthetical ending in
  digits does this at wrap boundaries): CommonMark renders such a line as prose, panache formats it as a nested list,
  and the two disagree.
