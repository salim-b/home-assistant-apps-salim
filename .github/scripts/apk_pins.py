#!/usr/bin/env python3
"""Shared apk-pin parsing for the apk-pin tooling – the single pin parser.

Consumers: the validate:apk-pins task (`.mise/tasks/validate/apk-pins.py`) and both jobs of the
apk-bump workflow (`.github/workflows/apk-bump.yaml`). The `pkg=version` regex plus the apk-add
backslash-continuation state machine exist only here; canary fixtures lock the behavior
(`mise run validate:apk-pin-parser`). Index/arch facts: root KNOWLEDGE.md §"apk package version
policy".
"""

from __future__ import annotations

import io
import re
import tarfile

# The pkg=version pin shape: package ids start alphanumeric, versions start with a digit (full
# pkgver-pkgrel form, the pkgrel suffix optional). The only definition – consumers import this
# module instead of restating the regex.
PIN_RE = re.compile(r"([A-Za-z0-9][\w.+-]*)=(\d[\w.:]+(?:-r\d+)?)")

# The Alpine repos the base images resolve against (Alpine's default repositories file: main
# before community) – merge order = precedence.
APK_REPOS = ("main", "community")

# HA arch names -> Alpine arch names (all others map 1:1).
HA_TO_ALPINE_ARCH = {"amd64": "x86_64", "i386": "x86"}


def parse_pins(text: str) -> dict[str, str]:
    """All apk pins in a Dockerfile text: {pkg: pin}, last occurrence wins.

    A pin counts from any line containing the literal substring `apk add` and – across backslash
    continuations – from every following line until one does not end with a backslash. The state
    machine is line-based and cannot see Docker's continuation semantics, so the non-pin-shaped
    tail of a continued RUN (e.g. after a mid-RUN `;`) stays scanned.
    """
    pins: dict[str, str] = {}
    in_apk = False
    for line in text.splitlines():
        if in_apk or "apk add" in line:
            in_apk = line.rstrip().endswith("\\")
        else:
            continue
        for pkg, pin in PIN_RE.findall(line):
            pins[pkg] = pin
    return pins


def pin_changes(base_text: str, head_text: str) -> dict[str, dict[str, str | None]]:
    """Changed pins between two Dockerfile versions: {pkg: {"old": ..., "new": ...}}.

    Diffing the pin sets parsed from the full Dockerfiles at both revisions – a long apk add
    block cannot be truncated by patch hunk boundaries.
    """
    base_pins, head_pins = parse_pins(base_text), parse_pins(head_text)
    changes: dict[str, dict[str, str | None]] = {}
    for pkg in set(base_pins) | set(head_pins):
        old, new = base_pins.get(pkg), head_pins.get(pkg)
        if old != new:
            changes[pkg] = {"old": old, "new": new}
    return changes


def build_branch(dockerfile_text: str) -> str | None:
    """Alpine branch from the Dockerfile's BUILD_FROM default (e.g. `3.24`), None without one."""
    match = re.search(r"(?m)^ARG BUILD_FROM=(\S+)", dockerfile_text)
    if not match:
        return None
    return match.group(1).rsplit(":", 1)[-1].lstrip("v")


def app_arches(config_text: str) -> list[str]:
    """HA arch list from a config.yaml text (block or flow form), [] when absent or unreadable.

    A missing trailing newline is normalized so the last block item still parses; item quotes are
    stripped in both forms.
    """
    if not config_text.endswith("\n"):
        config_text += "\n"
    match = re.search(r"(?m)^arch:\s*$\n((?:[ \t]+-[ \t]*\S.*\n)+)", config_text)
    if match:
        return [
            a.strip().strip("\"'")
            for a in re.findall(r"[ \t]+-[ \t]*(\S+)", match.group(1))
        ]
    match = re.search(r"(?m)^arch:\s*\[([^\]]+)\]", config_text)
    if match:
        return [a.strip().strip("\"'") for a in match.group(1).split(",") if a.strip()]
    return []


def alpine_arch(ha_arch: str) -> str:
    """Alpine arch name of a HA arch (amd64→x86_64, i386→x86, all others map 1:1)."""
    return HA_TO_ALPINE_ARCH.get(ha_arch, ha_arch)


def apkindex_url(branch: str, repo: str, arch: str) -> str:
    """dl-cdn APKINDEX tarball URL for one Alpine branch/repo/arch."""
    return (
        f"https://dl-cdn.alpinelinux.org/alpine/v{branch}/{repo}/{arch}/APKINDEX.tar.gz"
    )


def apkindex_text(tarball: bytes) -> str:
    """The APKINDEX member text of a dl-cdn index tarball.

    Raises ValueError for an unusable tarball – not a gzip/tar stream or truncated mid-stream
    (tarfile.TarError and EOFError normalized) or no APKINDEX member – the single error type
    consumers must handle.
    """
    try:
        with tarfile.open(fileobj=io.BytesIO(tarball), mode="r:gz") as tar:
            member = tar.extractfile("APKINDEX")
            data = member.read() if member is not None else None
    except (tarfile.TarError, EOFError) as err:
        msg = f"unreadable APKINDEX tarball: {err}"
        raise ValueError(msg) from err
    if data is None:
        msg = "APKINDEX missing from tarball"
        raise ValueError(msg)
    return data.decode()


def parse_apkindex(text: str) -> dict[str, str]:
    """{pkg: version} from a plain APKINDEX text (double-newline-separated stanzas, P/V fields)."""
    index: dict[str, str] = {}
    for block in text.split("\n\n"):
        fields: dict[str, str] = {}
        for line in block.splitlines():
            if ":" in line:
                key, _, value = line.partition(":")
                fields[key] = value
        if fields.get("P"):
            index[fields["P"]] = fields.get("V", "")
    return index


def merge_apkindexes(*repos: dict[str, str]) -> dict[str, str]:
    """Merge per-repo index maps, earlier arguments winning.

    Main before community – the base images' repositories order, a deterministic tie-break for
    the brief both-repos overlap while a package moves between repos.
    """
    merged: dict[str, str] = {}
    for repo in repos:
        for pkg, version in repo.items():
            merged.setdefault(pkg, version)
    return merged
