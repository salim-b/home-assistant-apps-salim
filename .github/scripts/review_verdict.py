#!/usr/bin/env python3
"""Helpers for the AI supply-chain review workflow.

Used by `.github/workflows/action-bump-review.yaml`. `extract` recovers the
reviewer's JSON verdict object from its raw CLI output – failing closed: any
output that does not match the verdict contract becomes an `unparsable`
verdict, which the workflow treats as risky. `render` turns a verdict JSON
into the Markdown section posted on the pull request.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

VALID_VERDICTS = ("clean", "risky")
DIGEST = re.compile(r"^[0-9a-f]{40}$")


def extract(raw_path: str, out_path: str) -> None:
    """Recover the first valid verdict JSON object from raw reviewer output.

    Scans the output for a JSON object whose `verdict` field matches the
    contract; when none is found, writes an `unparsable` verdict instead – the
    workflow classifies that as risky, so a malformed reviewer reply can never
    count as a pass.
    """
    raw = Path(raw_path).read_text(encoding="utf-8", errors="replace")
    decoder = json.JSONDecoder()
    found: dict[str, object] | None = None
    start = 0
    while found is None:
        brace = raw.find("{", start)
        if brace < 0:
            break
        try:
            obj, end = decoder.raw_decode(raw, brace)
        except ValueError:
            start = brace + 1
            continue
        if isinstance(obj, dict) and obj.get("verdict") in VALID_VERDICTS:
            found = obj
        else:
            start = end if end > brace else brace + 1
    if found is None:
        found = {
            "verdict": "unparsable",
            "confidence": 0,
            "summary": (
                "Reviewer output did not parse as the JSON verdict contract "
                "– treated as risky (fail closed)."
            ),
            "findings": [],
        }
    Path(out_path).write_text(json.dumps(found), encoding="utf-8")


def classify(old_path: str, new_path: str, out_path: str) -> None:
    """Classify action-pin changes between two revisions into entries.

    Reads `file<TAB>slug<TAB>ref` detail lines from both revisions, groups
    them per workflow file and slug, and emits one `etype<TAB>slug<TAB>old<TAB>new`
    row per actual transition: `added`/`removed` when a slug appears on one
    side only, `review`/`nondigest` for a single ref replacement (by digest
    shape), and `ambiguous` when a file pins a slug at multiple digests on
    both sides so the pairing cannot be determined. Identical transitions
    across files are deduplicated – their upstream compare is the same.
    """

    def load(path: str) -> dict[tuple[str, str], set[str]]:
        pins: dict[tuple[str, str], set[str]] = {}
        for line in Path(path).read_text(encoding="utf-8").splitlines():
            if not line:
                continue
            file, slug, ref = line.split("\t", 2)
            pins.setdefault((file, slug), set()).add(ref)
        return pins

    old, new = load(old_path), load(new_path)
    rows: list[tuple[str, str, str, str]] = []
    for key in sorted(set(old) | set(new)):
        slug = key[1]
        o, n = old.get(key, set()), new.get(key, set())
        if o == n:
            continue
        if not o:
            rows.append(("added", slug, "-", " ".join(sorted(n))))
        elif not n:
            rows.append(("removed", slug, " ".join(sorted(o)), "-"))
        elif len(o) == 1 and len(n) == 1:
            ov, nv = min(o), min(n)
            etype = (
                "review"
                if DIGEST.fullmatch(ov) and DIGEST.fullmatch(nv)
                else "nondigest"
            )
            rows.append((etype, slug, ov, nv))
        else:
            rows.append(("ambiguous", slug, " ".join(sorted(o)), " ".join(sorted(n))))
    deduped = list(dict.fromkeys(rows))
    Path(out_path).write_text(
        "".join("\t".join(row) + "\n" for row in deduped), encoding="utf-8"
    )


def render(
    verdict_path: str,
    idx: str,
    slug: str,
    old: str,
    new: str,
    mark: str,
    out_path: str,
) -> None:
    """Render one verdict as the Markdown section for the PR comment."""
    verdict: dict[str, object] = json.loads(
        Path(verdict_path).read_text(encoding="utf-8")
    )
    findings = verdict.get("findings", [])
    lines = [
        f"### {idx}. `{slug}`",
        "",
        f"- Refs: `{old}` → `{new}`",
        f"- Verdict: **{mark}** (confidence {verdict.get('confidence', '?')})",
        "",
        str(verdict.get("summary", "")),
        "",
    ]
    if isinstance(findings, list):
        for finding in findings:
            if not isinstance(finding, dict):
                continue
            item: dict[str, object] = finding
            # Backticks inside evidence would break the enclosing code span.
            evidence = str(item.get("evidence", "")).replace("`", "'")
            lines.append(
                f"- **{item.get('severity', '?')}** – {item.get('title', '?')}"
            )
            lines.append(f"  - Why: {item.get('why', '')}")
            lines.append(f"  - Evidence: `{evidence}`")
    Path(out_path).write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    """Dispatch on argv[1]: `classify`, `extract` or `render`."""
    args = sys.argv[1:]
    if len(args) == 4 and args[0] == "classify":
        classify(args[1], args[2], args[3])
    elif len(args) == 3 and args[0] == "extract":
        extract(args[1], args[2])
    elif len(args) == 8 and args[0] == "render":
        render(*args[1:])
    else:
        print(
            "usage: review_verdict.py classify OLD OUT | extract RAW OUT | "
            "render VERDICT IDX SLUG OLD NEW MARK OUT",
            file=sys.stderr,
        )
        sys.exit(2)


if __name__ == "__main__":
    main()
