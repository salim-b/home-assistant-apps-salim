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
import sys
from pathlib import Path

VALID_VERDICTS = ("clean", "risky")


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
    """Dispatch on argv[1]: `extract` or `render`."""
    if len(sys.argv) < 2 or sys.argv[1] not in ("extract", "render"):
        print(
            "usage: review_verdict.py extract RAW OUT | "
            "render VERDICT IDX SLUG OLD NEW MARK OUT",
            file=sys.stderr,
        )
        sys.exit(2)
    if sys.argv[1] == "extract":
        extract(sys.argv[2], sys.argv[3])
    else:
        render(*sys.argv[2:8])


if __name__ == "__main__":
    main()
