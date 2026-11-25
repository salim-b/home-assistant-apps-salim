#!/usr/bin/env python3
# fmt: off
#MISE description="Check pinned apk package versions in app Dockerfiles against the Alpine binary indexes (drift alarm)"
#USAGE arg "[app]" help="App directory to check (default: all apps)"
# fmt: on

"""validate:apk-pins: compare pinned apk package versions in app Dockerfiles against the Alpine binary indexes.

Drift = guided release (policy + why: root KNOWLEDGE.md §"apk package version policy"); CI runs
this task only on main pushes and the daily cron, never in the PR gate.
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


def _apkindex_versions(branch: str, package: str) -> dict[str, str]:
    """Version of <package> in the Alpine v<branch> binary indexes, per arch.

    The BINARY index (dl-cdn APKINDEX) is what `apk add` resolves, not the aports APKBUILD source
    branch (a pkgrel commit can outrun the published packages; policy: root KNOWLEDGE.md §apk
    package version policy). Cached for APKINDEX_TTL so local runs stay snappy while the daily
    cron sees fresh data.
    """
    versions: dict[str, str] = {}
    for arch in ("x86_64", "aarch64"):
        dest = CACHE / f"apkindex-v{branch}-{arch}"
        if not dest.is_file() or time.time() - dest.stat().st_mtime > APKINDEX_TTL:
            for repo in ("community", "main"):
                try:
                    raw = urllib.request.urlopen(  # noqa: S310 – apkindex_url is the fixed https dl-cdn URL
                        apk_pins.apkindex_url(branch, repo, arch), timeout=60
                    ).read()
                    break
                except OSError:
                    raw = b""
            if not raw:
                fail("apk-pins", f"cannot fetch any APKINDEX for v{branch}/{arch}")
                continue
            try:
                index_text = apk_pins.apkindex_text(raw)
            except ValueError:
                fail("apk-pins", f"APKINDEX missing from tarball (v{branch}/{arch})")
                continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(index_text)
        ver = apk_pins.parse_apkindex(dest.read_text()).get(package)
        if ver is not None:
            versions[arch] = ver
    return versions


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

        pins = apk_pins.parse_pins(text)
        if not pins:
            continue

        for pkg, pin in pins.items():
            versions = _apkindex_versions(branch, pkg)
            if not versions:
                continue
            for arch, ver in versions.items():
                if ver != pin:
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
