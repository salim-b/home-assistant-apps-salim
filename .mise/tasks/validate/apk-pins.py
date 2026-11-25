#!/usr/bin/env python3
# fmt: off
#MISE description="Check pinned apk package versions in app Dockerfiles against the Alpine binary indexes (drift alarm)"
#USAGE arg "[app]" help="App directory to check (default: all apps)"
# fmt: on

"""validate:apk-pins: compare pinned apk package versions in app Dockerfiles against the Alpine binary indexes.

Drift = guided release (policy + why: root KNOWLEDGE.md §"apk package version policy"); CI runs
this task only on main pushes and the daily cron, never in the PR gate. Parsing and index/arch
semantics are the shared apk_pins module (canary fixtures: mise run validate:apk-pin-parser).
"""

from __future__ import annotations

import os
import pathlib
import sys
import time
import urllib.request

ROOT = pathlib.Path(os.environ.get("MISE_PROJECT_ROOT", "."))

# The shared pin parser (.github/scripts/apk_pins.py) – single source of the pin regex, the
# apk-add state machine and the index helpers (canary fixtures: mise run validate:apk-pin-parser).
sys.path.insert(0, str(ROOT / ".github" / "scripts"))
import apk_pins  # noqa: E402

CACHE = (
    pathlib.Path(os.environ.get("XDG_CACHE_HOME", pathlib.Path.home() / ".cache"))
    / "ha-apps-apk-pins"
)

APKINDEX_TTL = (
    24 * 3600
)  # the daily CI cron should see Alpine-side repoints within a day

problems: list[str] = []
_INDEX_MAPS: dict[tuple[str, str], dict[str, str] | None] = {}


def fail(app: str, msg: str) -> None:
    """Record a problem for app (printed at exit with a nonzero status)."""
    problems.append(f"[{app}] {msg}")


def find_apps() -> list[str]:
    """The apps to validate: the optional [app] arg, or all app dirs.

    `usage_app` env var (mise) or first argv token (direct runs); empty/unset
    means all apps, like the optional arg's shell `:-` expansion (empty ≡ unset).
    """
    for src in (
        os.environ.get("usage_app", ""),
        sys.argv[1] if len(sys.argv) > 1 else "",
    ):
        if src and not src.startswith("-"):
            return [src]
    return sorted(
        p.name
        for p in ROOT.iterdir()
        if (p / "config.yaml").is_file() or (p / "config.yml").is_file()
    )


def _apkindex_maps(branch: str, arch: str) -> dict[str, str] | None:
    """Merged {pkg: version} for one Alpine branch/arch: both repos, main winning.

    The BINARY index (dl-cdn APKINDEX) is what `apk add` resolves, not the aports APKBUILD source
    branch (a pkgrel commit can outrun the published packages; policy: root KNOWLEDGE.md §apk
    package version policy). Both repos are consulted, so a package that lives only in main is
    checked too; on the rare both-repos overlap main wins (the base images' repositories order).
    Any single-repo fetch/tarball failure records a problem and yields None – the caller skips
    that branch/arch's comparisons instead of comparing against a partial merge. Disk-cached per
    (branch, repo, arch) for APKINDEX_TTL so local runs stay snappy while the daily cron sees
    fresh data.
    """
    key = (branch, arch)
    if key in _INDEX_MAPS:
        return _INDEX_MAPS[key]
    maps: list[dict[str, str]] = []
    failed = False
    for repo in apk_pins.APK_REPOS:
        dest = CACHE / f"apkindex-v{branch}-{repo}-{arch}"
        if not dest.is_file() or time.time() - dest.stat().st_mtime > APKINDEX_TTL:
            try:
                raw = urllib.request.urlopen(  # noqa: S310 – apkindex_url is the fixed https dl-cdn URL
                    apk_pins.apkindex_url(branch, repo, arch), timeout=60
                ).read()
            except OSError:
                raw = b""
            if not raw:
                fail("apk-pins", f"cannot fetch APKINDEX for v{branch}/{repo}/{arch}")
                failed = True
                continue
            try:
                index_text = apk_pins.apkindex_text(raw)
            except ValueError as err:
                fail(
                    "apk-pins",
                    f"unusable APKINDEX tarball (v{branch}/{repo}/{arch}): {err}",
                )
                failed = True
                continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(index_text)
        maps.append(apk_pins.parse_apkindex(dest.read_text()))
    if failed:
        _INDEX_MAPS[key] = None
        return None
    merged = apk_pins.merge_apkindexes(*maps)
    _INDEX_MAPS[key] = merged
    return merged


def main() -> int:
    """Check every app's pinned apk versions against the Alpine indexes; exits nonzero on drift."""
    for app in find_apps():
        dockerfile = ROOT / app / "Dockerfile"
        if not dockerfile.is_file():
            continue
        text = dockerfile.read_text()
        branch = apk_pins.build_branch(text)
        if not branch:
            continue
        config = ROOT / app / "config.yaml"
        if not config.is_file():
            config = ROOT / app / "config.yml"
        ha_arches = apk_pins.app_arches(config.read_text()) if config.is_file() else []
        if not ha_arches:
            # `arch:` is required by the supervisor app schema (validate:apps gates it) – a
            # missing list means a malformed config, so fail loudly instead of silently
            # skipping the app's pins.
            fail(
                app,
                "cannot derive the arch list from config.yaml/yml – unknown which "
                "Alpine indexes to compare",
            )
            continue
        pins = apk_pins.parse_pins(text)
        if not pins:
            continue

        for pkg, pin in pins.items():
            for ha_arch in ha_arches:
                arch = apk_pins.alpine_arch(ha_arch)
                index = _apkindex_maps(branch, arch)
                if index is None:
                    continue
                ver = index.get(pkg)
                if ver is not None and ver != pin:
                    fail(
                        app,
                        f"pinned apk {pkg}={pin} differs from the Alpine "
                        f"v{branch} {arch} index ({ver}): bump the pin and "
                        f"the app's config.yaml version + changelog (one "
                        f"release per package version – the index serves "
                        f"only the current version, a stale pin breaks the "
                        f"build)",
                    )

    if problems:
        print("\nAPK PIN DRIFT:")
        for p in problems:
            print(f"  {p}")
        return 1
    print("validate:apk-pins OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
