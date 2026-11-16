#!/usr/bin/env python3
# fmt: off
#MISE description="Prefix vendored agent skills' frontmatter name: fields with entire- (post-sync step)"
# fmt: on

"""skills:prefix-names: prefix vendored agent skills' frontmatter ``name:`` fields with ``entire-``.

Post-sync step for the vendir-vendored skills (root KNOWLEDGE.md §"Vendored agent skills"): vendir writes
upstream-verbatim copies whose ``name:`` fields are unprefixed, this task rewrites them to match the
``entire-`` directory-name prefix. Idempotent: already-prefixed names are left untouched.
"""

from __future__ import annotations

import os
import pathlib
import sys

ROOT = pathlib.Path(os.environ.get("MISE_PROJECT_ROOT", "."))
SKILLS_DIR = ROOT / ".agents" / "skills"
PREFIX = "entire-"


def prefix_frontmatter_name(lines: list[str]) -> str | None:
    """Prefix the top-level ``name:`` field of a SKILL.md frontmatter; report the old name.

    Args:
        lines: The file content split into lines (without their newlines), edited in place.

    Returns:
        The first rewritten, unprefixed name, or None when the file carries no rewriteable
        top-level ``name:`` field (no frontmatter, no ``name:`` key, or already prefixed).
    """
    if not lines or lines[0] != "---":
        return None
    try:
        end = lines.index("---", 1)
    except ValueError:
        return None
    old_name = None
    for i in range(1, end):
        if not lines[i].startswith("name:"):
            continue
        value = lines[i][len("name:") :].strip()
        if value and not value.startswith(PREFIX):
            lines[i] = f"name: {PREFIX}{value}"
            if old_name is None:
                old_name = value
    return old_name


def main() -> int:
    """Rewrite every vendored skill's frontmatter ``name:`` field; print one status line per file."""
    changed = 0
    for skill_md in sorted(SKILLS_DIR.glob("entire-*/SKILL.md")):
        rel = skill_md.relative_to(ROOT)
        lines = skill_md.read_text(encoding="utf-8").split("\n")
        old_name = prefix_frontmatter_name(lines)
        if old_name is None:
            print(f"{rel}: frontmatter name already prefixed or absent")
            continue
        skill_md.write_text("\n".join(lines), encoding="utf-8")
        changed += 1
        print(f"{rel}: name: {old_name} -> name: {PREFIX}{old_name}")
    print(f"{changed} file(s) rewritten")
    return 0


if __name__ == "__main__":
    sys.exit(main())
