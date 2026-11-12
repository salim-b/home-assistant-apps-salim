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

import io
import os
import pathlib
import re
import sys
import tarfile
import time
import urllib.request

ROOT = pathlib.Path(os.environ.get("MISE_PROJECT_ROOT", "."))

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
                url = (
                    f"https://dl-cdn.alpinelinux.org/alpine/v{branch}"
                    f"/{repo}/{arch}/APKINDEX.tar.gz"
                )
                try:
                    raw = urllib.request.urlopen(url).read()
                    break
                except OSError:
                    raw = b""
            if not raw:
                fail("apk-pins", f"cannot fetch any APKINDEX for v{branch}/{arch}")
                continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as tar:
                index = tar.extractfile("APKINDEX").read().decode()
            dest.write_text(index)
        text = dest.read_text()
        for block in text.split("\n\n"):
            fields = {
                line.split(":", 1)[0]: line.split(":", 1)[1]
                for line in block.splitlines()
                if ":" in line
            }
            if fields.get("P") == package:
                versions[arch] = fields.get("V", "")
                break
    return versions


def main() -> int:
    """Check every app's pinned apk versions against the Alpine indexes; exits nonzero on drift."""
    for app in find_apps():
        dockerfile = ROOT / app / "Dockerfile"
        if not dockerfile.is_file():
            continue
        text = dockerfile.read_text()
        base = re.search(r"^ARG BUILD_FROM=([^\n]+)$", text, re.MULTILINE)
        if not base:
            continue
        branch = base.group(1).strip().rsplit(":", 1)[-1].lstrip("v")

        pins: list[tuple[str, str]] = []
        in_apk = False
        for raw in text.splitlines():
            found = re.findall(r"([A-Za-z0-9][\w.+-]*)=(\d[\w.:]+(?:-r\d+)?)", raw)
            if in_apk:
                pins.extend(found)
                if not raw.rstrip().endswith("\\"):
                    in_apk = False
            elif "apk add" in raw:
                pins.extend(found)
                in_apk = raw.rstrip().endswith("\\")
        if not pins:
            continue

        for pkg, pin in pins:
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
                        f"release per package version - the index serves "
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
