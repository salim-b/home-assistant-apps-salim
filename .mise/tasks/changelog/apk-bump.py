#!/usr/bin/env python3
#MISE description="Insert the templated changelog section for an apk pin bump (shared by the `apk-bump` CI workflow and local runs)"
#USAGE flag "--app <app>" required=#true help="App directory whose CHANGELOG.md is updated"
#USAGE flag "--pkg <pkg>" required=#true help="Pinned apk package name, e.g. hd-idle"
#USAGE flag "--old <old>" required=#true help="Old pin (full pkgver-pkgrel), e.g. 1.22-r7"
#USAGE flag "--new <new>" required=#true help="New pin (full pkgver-pkgrel), e.g. 1.22-r8"
#USAGE flag "--version <version>" required=#true help="App version the section is titled with (the version bumpVersions wrote in the same Renovate PR)"
#USAGE flag "--dry-run" help="Print the section that would be inserted instead of writing CHANGELOG.md"

"""changelog:apk-bump: insert the templated changelog section for an apk pin bump.

The Renovate apk-pin PR is merged without a changelog entry - the apk-bump workflow's changelog
job runs this task post-merge to fill it (policy: root KNOWLEDGE.md §apk package version policy);
local runs share the same code path. Idempotent: the `## <version>` section is inserted only when
that heading is absent. The bullet is end-user phrased ("Updated the bundled <pkg> from <old> to
<new>") and greedy-wrapped at the repository's Markdown width (panache, 120 chars) so `mise run
fmt` right after the insertion is a no-op and the dry-run output matches the committed form.
"""
from __future__ import annotations

import os
import pathlib
import re
import sys

ROOT = pathlib.Path(os.environ.get("MISE_PROJECT_ROOT", "."))

WIDTH = 120  # panache's reflow width (panache.toml)
CONTINUATION_INDENT = "  "  # Markdown list-item continuation indent


def _argv_value(name: str) -> str:
    """CLI fallback for direct (non-mise) runs: `--<name> <value>` in argv.
    mise passes options as env vars; this keeps direct invocations honest."""
    flag = f"--{name}"
    if flag in sys.argv:
        idx = sys.argv.index(flag)
        if idx + 1 < len(sys.argv):
            return sys.argv[idx + 1]
    return ""


def _val(name: str) -> str:
    """Read a mise #USAGE option value (env var; argv fallback for direct runs).
    The spec declares the flag required=true, so mise fails a missing flag
    before the script runs - but empty values pass mise's check and are
    rejected here (the Python equivalent of the shell's `${usage_name:?}`)."""
    value = os.environ.get(f"usage_{name.replace('-', '_')}", "") or _argv_value(name)
    if not value:
        sys.exit(f"changelog:apk-bump: --{name} must not be empty")
    return value


def _flag(name: str) -> bool:
    """Read a mise #USAGE boolean flag (env vars, or argv for direct runs)."""
    env = f"usage_{name.replace('-', '_')}"
    if os.environ.get(env, "").lower() in ("true", "1") or f"--{name}" in sys.argv:
        return True
    return False


def wrap_bullet(text: str) -> list[str]:
    """Greedy word wrap at WIDTH with a CONTINUATION_INDENT continuation, so
    the emitted bullet is already in panache's reflowed form (`mise run fmt`
    after the insertion does not rewrite it)."""
    words = text.split()
    lines: list[str] = []
    current = ""
    for word in words:
        candidate = f"{current} {word}" if current else word
        indent = CONTINUATION_INDENT if lines else ""
        if len(indent + candidate) > WIDTH and current:
            lines.append(indent + current)
            current = word
        else:
            current = candidate
    if current:
        lines.append((CONTINUATION_INDENT if lines else "") + current)
    return lines


def bullet(pkg: str, old: str, new: str) -> str:
    """The changelog bullet for one apk pin bump."""
    prefix = f"- Updated the bundled {pkg} from {old} to {new}"
    if old.rsplit("-", 1)[0] == new.rsplit("-", 1)[0]:
        # pkgrel-only: same upstream release, Alpine repackaged it.
        return f"{prefix} (Alpine packaging update)."
    return f"{prefix}."


def main() -> int:
    app = _val("app")
    pkg = _val("pkg")
    old = _val("old")
    new = _val("new")
    version = _val("version")
    dry_run = _flag("dry-run")

    if old == new:
        sys.exit(f"changelog:apk-bump: --old and --new are identical ({old}) - nothing to record")
    changelog = ROOT / app / "CHANGELOG.md"
    if not changelog.is_file():
        sys.exit(f"changelog:apk-bump: {changelog} does not exist (app '{app}')")

    heading = f"## {version}"
    bullet_lines = wrap_bullet(bullet(pkg, old, new))

    lines = changelog.read_text().splitlines()

    # Idempotency: any existing `## <version>` heading (with a trailing qualifier) counts as present.
    heading_re = re.compile(rf"^## {re.escape(version)}(?:\s|$)")
    if any(heading_re.match(line) for line in lines):
        print(f"changelog:apk-bump: [{app}] a '## {version}' section already exists - nothing to do")
        return 0

    anchor = next(
        (idx for idx, line in enumerate(lines) if line.strip() == "# Changelog"), None
    )
    if anchor is None:
        sys.exit(
            f"changelog:apk-bump: {changelog} has no '# Changelog' heading - unexpected "
            f"structure, refusing to modify"
        )

    rest = lines[anchor + 1:]
    while rest and not rest[0].strip():
        rest.pop(0)
    section = ["", heading, "", *bullet_lines, ""]
    new_lines = lines[: anchor + 1] + section + rest
    new_text = "\n".join(new_lines) + "\n"

    if dry_run:
        print(
            f"changelog:apk-bump: [{app}] would insert after '# Changelog' "
            f"({pkg} {old} -> {new}):"
        )
        print()
        print("\n".join(section).strip("\n"))
        print()
        return 0

    changelog.write_text(new_text)
    print(f"changelog:apk-bump: [{app}] inserted '## {version}' section ({pkg} {old} -> {new})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
