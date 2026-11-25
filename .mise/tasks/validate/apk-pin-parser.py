#!/usr/bin/env python3
# fmt: off
#MISE description="Canary fixtures locking the shared apk pin parser's behavior (apk_pins module)"
# fmt: on

"""validate:apk-pin-parser: canary fixtures for the shared apk pin parser (.github/scripts/apk_pins.py).

The validate:apk-pins task and both apk-bump workflow jobs parse Dockerfiles through one module –
these fixtures lock its behavior so a parser change cannot silently diverge the three consumers
(facts: root KNOWLEDGE.md §"apk package version policy"). Hermetic: no network, no app files.
"""

from __future__ import annotations

import os
import pathlib
import sys
from collections.abc import Callable

ROOT = pathlib.Path(os.environ.get("MISE_PROJECT_ROOT", "."))

# The module under test – imported via a runtime sys.path insert like every consumer (ty resolves
# it through ty.toml's [environment].extra-paths).
sys.path.insert(0, str(ROOT / ".github" / "scripts"))
import apk_pins  # noqa: E402

# The three consumers of apk_pins: the validate task and the two jobs of the apk-bump workflow
# (both jobs live in one workflow file).
TASK = ROOT / ".mise" / "tasks" / "validate" / "apk-pins.py"
WORKFLOW = ROOT / ".github" / "workflows" / "apk-bump.yaml"
LIB = ROOT / ".github" / "scripts" / "apk_pins.py"

# Distinctive fragment of PIN_RE – triplication canary: after the dedupe it must exist only in
# the module (this file carries it too, but is not scanned).
PIN_REGEX_FRAGMENT = r"[\w.+-]"

_CASES: list[tuple[str, Callable[[], None]]] = []


def _case(name: str) -> Callable[[Callable[[], None]], Callable[[], None]]:
    """Register the decorated zero-arg function as a fixture case under name."""

    def _register(fn: Callable[[], None]) -> Callable[[], None]:
        _CASES.append((name, fn))
        return fn

    return _register


# A realistic app Dockerfile shape (hd-idle): the trigger line ends with a backslash, the package
# list spans continuation lines, the block closes on the last pin line; pin-shaped lines outside
# any apk add block (ENV, comments) must not count.
_DOCKERFILE_BLOCKS = """\
FROM ghcr.io/home-assistant/base:3.24
ARG BUILD_FROM=ghcr.io/home-assistant/base:3.24

RUN apk add --no-cache \\
  hd-idle=1.22-r8 \\
  smartmontools=7.5-r0

# e2fsprogs=1.47.1-r0 outside any add block – not a pin
ENV IDLE_THRESHOLD=600
"""

# apk add triggered mid-RUN (after a `set -eux;` continuation) with a package list that does not
# close the block until a line without a trailing backslash.
_DOCKERFILE_MID_RUN = """\
RUN set -eux; \\
    apk add --no-cache \\
        nfs-utils=2.6.4-r6 \\
        e2fsprogs=1.47.1-r0 \\
    ; \\
    chmod +x /usr/bin/exportfs-apply
"""

# The trigger is the literal substring `apk add` – comments included. A comment line carrying it
# together with a pin-shaped token is therefore a pin source (locked pre-existing behavior, shared
# by all three consumers – word app Dockerfile comments accordingly).
_DOCKERFILE_COMMENT_TRIGGER = """\
# apk add pulled hd-idle=1.22-r7 during the last build
ENV HD_IDLE_ARGS=""
"""


@_case("parse pins: apk add blocks across backslash continuations")
def _parse_pins_blocks() -> None:
    """Trigger line plus continuation lines count; pin-shaped lines outside blocks do not."""
    parsed = apk_pins.parse_pins(_DOCKERFILE_BLOCKS)
    assert parsed == {
        "hd-idle": "1.22-r8",
        "smartmontools": "7.5-r0",
    }, parsed


@_case("parse pins: mid-RUN trigger, block stays open past the `;` line")
def _parse_pins_mid_run() -> None:
    """A mid-RUN trigger keeps the state machine inside the block past the `;` line.

    The line-based machine cannot see Docker's continuation semantics, so the RUN's non-pin-shaped
    tail stays scanned – harmless while pin-shaped tokens do not appear there.
    """
    parsed = apk_pins.parse_pins(_DOCKERFILE_MID_RUN)
    assert parsed == {
        "nfs-utils": "2.6.4-r6",
        "e2fsprogs": "1.47.1-r0",
    }, parsed


@_case("parse pins: last occurrence wins")
def _parse_pins_last_wins() -> None:
    """Duplicate pins of one package collapse to the last occurrence."""
    text = "RUN apk add --no-cache \\\n  hd-idle=1.22-r7 \\\n  hd-idle=1.22-r8\n"
    assert apk_pins.parse_pins(text) == {"hd-idle": "1.22-r8"}


@_case("parse pins: separate blocks accumulate")
def _parse_pins_two_blocks() -> None:
    """A closed block re-arms the state machine: a later apk add block counts again."""
    text = "RUN apk add --no-cache hd-idle=1.22-r8\nCOPY rootfs/ /\n"
    text += "RUN apk add --no-cache smartmontools=7.5-r0\n"
    assert apk_pins.parse_pins(text) == {
        "hd-idle": "1.22-r8",
        "smartmontools": "7.5-r0",
    }


@_case("parse pins: no apk add – nothing counts")
def _parse_pins_no_apk() -> None:
    """Without the trigger substring, pin-shaped ENV values and comments stay unparsed."""
    text = "FROM alpine:3.20\nENV PKG_VER=1.2-r0\n# nfs-utils=2.6.4-r6 in a comment\nCOPY rootfs/ /\n"
    assert apk_pins.parse_pins(text) == {}


@_case("parse pins: the trigger substring reaches into comments")
def _parse_pins_comment_trigger() -> None:
    """A comment line carrying `apk add` plus a pin-shaped token is a pin source.

    Locked pre-existing behavior of all three consumers – the trigger is the literal substring,
    so app Dockerfile comments must be worded accordingly.
    """
    parsed = apk_pins.parse_pins(_DOCKERFILE_COMMENT_TRIGGER)
    assert parsed == {"hd-idle": "1.22-r7"}, parsed


@_case("pin changes: changed, added, removed")
def _pin_changes() -> None:
    """Diffing two Dockerfile versions reports old/new per package, None on one side."""
    base = "RUN apk add --no-cache \\\n  a=1.0-r0 \\\n  b=2.0-r0\n"
    head = "RUN apk add --no-cache \\\n  a=1.0-r1 \\\n  c=3.0-r0\n"
    assert apk_pins.pin_changes(base, head) == {
        "a": {"old": "1.0-r0", "new": "1.0-r1"},
        "b": {"old": "2.0-r0", "new": None},
        "c": {"old": None, "new": "3.0-r0"},
    }
    assert apk_pins.pin_changes(base, base) == {}


@_case("branch: BUILD_FROM default tag after the last colon, optional v prefix")
def _build_branch() -> None:
    """`ghcr.io/home-assistant/base:3.24` yields `3.24`, `:v3.19` yields `3.19`; no ARG yields None."""
    assert (
        apk_pins.build_branch("ARG BUILD_FROM=ghcr.io/home-assistant/base:3.24\n")
        == "3.24"
    )
    assert (
        apk_pins.build_branch("ARG BUILD_FROM=ghcr.io/home-assistant/base:v3.19\n")
        == "3.19"
    )
    assert apk_pins.build_branch("FROM alpine:3.20\n") is None


@_case("arches: block and flow forms, trailing newline optional, absent list")
def _app_arches() -> None:
    """Block `- item` lists and flow `[a, b]` lists parse, trailing newline or not."""
    assert apk_pins.app_arches("arch:\n  - aarch64\n  - amd64\n") == [
        "aarch64",
        "amd64",
    ]
    assert apk_pins.app_arches("arch:\n  - aarch64\n  - amd64") == ["aarch64", "amd64"]
    assert apk_pins.app_arches("arch: [aarch64, amd64]\n") == ["aarch64", "amd64"]
    assert apk_pins.app_arches("name: x\n") == []


@_case("arch names: HA -> Alpine mapping")
def _alpine_arch() -> None:
    """amd64→x86_64 and i386→x86 map; other HA names pass through 1:1."""
    assert apk_pins.alpine_arch("amd64") == "x86_64"
    assert apk_pins.alpine_arch("i386") == "x86"
    assert apk_pins.alpine_arch("aarch64") == "aarch64"


@_case("APKINDEX text: stanza P/V fields")
def _parse_apkindex() -> None:
    """Double-newline-separated stanzas map P (package) to V (version); other fields are ignored."""
    text = "P:hd-idle\nV:1.22-r8\np:hd-idle daemon\n\nP:e2fsprogs\nV:1.47.1-r0\n\n"
    assert apk_pins.parse_apkindex(text) == {
        "hd-idle": "1.22-r8",
        "e2fsprogs": "1.47.1-r0",
    }


@_case("repo merge: main wins, community fills the gaps")
def _merge_apkindexes() -> None:
    """Earlier merge arguments (main) take precedence; packages only in community are kept."""
    main: dict[str, str] = {"pkg": "1.0-r8", "mainonly": "2.0-r0"}
    community: dict[str, str] = {"pkg": "1.0-r7", "comonly": "3.0-r0"}
    assert apk_pins.merge_apkindexes(main, community) == {
        "pkg": "1.0-r8",
        "mainonly": "2.0-r0",
        "comonly": "3.0-r0",
    }


@_case("wiring: every consumer imports apk_pins; the pin regex lives only there")
def _wiring() -> None:
    """Triplication canary: the pin regex appears in no consumer; every consumer imports it."""
    task, workflow, lib = TASK.read_text(), WORKFLOW.read_text(), LIB.read_text()
    assert PIN_REGEX_FRAGMENT not in task, "inline pin regex in the apk-pins task"
    assert PIN_REGEX_FRAGMENT not in workflow, (
        "inline pin regex in the apk-bump workflow"
    )
    assert PIN_REGEX_FRAGMENT in lib, "pin regex fragment missing from apk_pins.py"
    assert "import apk_pins" in task, "apk-pins task does not import apk_pins"
    assert workflow.count("import apk_pins") >= 2, (
        "an apk-bump job does not import apk_pins"
    )


def main() -> int:
    """Run every fixture case; exit nonzero listing the failures."""
    failures: list[str] = []
    for name, case_fn in _CASES:
        try:
            case_fn()
        except AssertionError as err:
            failures.append(f"{name}: {err}")
        except Exception as err:  # noqa: BLE001 – a crashing case is a canary failure, not a crash
            failures.append(f"{name}: unexpected {type(err).__name__}: {err}")

    if failures:
        print("\nAPK PIN PARSER CANARY FAILURES:")
        for failure in failures:
            print(f"  {failure}")
        return 1
    print(f"validate:apk-pin-parser OK ({len(_CASES)} cases)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
