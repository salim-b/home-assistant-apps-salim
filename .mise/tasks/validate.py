#!/usr/bin/env -S uv run --with voluptuous --with pyyaml --with jsonschema python3
#MISE description="Validate app configs and translations against HA Supervisor schemas"
#USAGE arg "[app]" help="App directory to validate (default: all apps)"
#USAGE flag "--schemas-only" help="Only refetch the pinned Supervisor schemas"

"""Validation harness: supervisor-side semantics the CI app linter does not
cover, at a pinned supervisor ref (what each check is for: .agents/skills/ha-app-tooling).

Parses all app YAML files (catching parse errors early); validates translations against the
supervisor's voluptuous schemas (AST-extracted from the pinned ref - no drifting copies) and the
AppArmor profile against the supervisor's profile-name regex (exactly one top-level profile);
cross-checks translation 'configuration' keys vs schema keys (incl. nested 'fields') and
'network' keys (lowercase!) vs config.yaml 'ports'; schema-validates .rumdl.toml and
.panache.toml against their published schemas (.github/renovate.json is instead gated by the
official renovate-config-validator in the hk lint stack); canary-checks that rumdl's
autofix stays disabled (panache owns formatting; see .rumdl.toml `fixable`); verifies apk pins
against the Alpine binary indexes (policy: root KNOWLEDGE.md §apk package version policy).
"""
from __future__ import annotations

import ast
import io
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import tomllib
import urllib.request

import voluptuous
import yaml

ROOT = pathlib.Path(os.environ.get("MISE_PROJECT_ROOT", "."))


def _supervisor_ref() -> str:
    """Ref pin (single source: [vars] in mise.toml)."""
    ref = os.environ.get("MISE_VAR_supervisor_ref")
    if ref:
        return ref
    try:
        import tomllib

        with open(ROOT / "mise.toml", "rb") as f:
            return tomllib.load(f)["vars"]["supervisor_ref"]
    except Exception:
        sys.exit("cannot determine supervisor ref (mise.toml [vars].supervisor_ref)")


REF = _supervisor_ref()
RAW = "https://raw.githubusercontent.com/home-assistant/supervisor"
CACHE = pathlib.Path(
    os.environ.get("XDG_CACHE_HOME", pathlib.Path.home() / ".cache")
) / "ha-apps-supervisor-schemas" / REF

# supervisor.const ATTR_* names the schemas reference; fetched from const.py at the pinned ref
CONST_NAMES: set[str] = set()
SCHEMA_NAMES = ("SCHEMA_TRANSLATION_CONFIGURATION", "SCHEMA_APP_TRANSLATIONS")
APPARMOR_RE_NAME = "RE_PROFILE"


def fetch(name: str) -> str:
    dest = CACHE / name
    if dest.is_file():
        return dest.read_text()
    dest.parent.mkdir(parents=True, exist_ok=True)
    url = f"{RAW}/{REF}/{name}"
    print(f"fetching {url}")
    dest.write_text(urllib.request.urlopen(url).read().decode())
    return dest.read_text()


def extract(path: str, names: tuple[str, ...] | str) -> dict[str, str]:
    """Extract module-level constant/schema assignments via AST."""
    want = {names} if isinstance(names, str) else set(names)
    tree = ast.parse(fetch(path))
    out: dict[str, str] = {}
    for node in tree.body:
        targets = []
        value = None
        if isinstance(node, ast.Assign):
            targets = [t.id for t in node.targets if isinstance(t, ast.Name)]
            value = node.value
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            targets = [node.target.id]
            value = node.value
        for t in targets:
            if t in want and value is not None:
                out[t] = ast.unparse(value)
    missing = want - out.keys()
    if missing:
        sys.exit(f"could not extract {missing} from {path} at ref {REF}")
    return out


def supervisor_constants() -> dict[str, str]:
    """ATTR_* names referenced by the extracted schemas."""
    consts = extract("supervisor/const.py", tuple(CONST_NAMES))
    return {k: ast.literal_eval(v) for k, v in consts.items()}


def find_apps() -> list[str]:
    if len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
        return [sys.argv[1]]
    return sorted(
        p.name
        for p in ROOT.iterdir()
        if (p / "config.yaml").is_file() or (p / "config.yml").is_file()
    )


problems: list[str] = []


def fail(app: str, msg: str) -> None:
    problems.append(f"[{app}] {msg}")


def _flag(name: str) -> bool:
    """Read a mise #USAGE boolean flag (exposed to the task as env vars)."""
    for env in (f"usage_{name.replace('-', '_')}", name.upper().replace("-", "_")):
        if os.environ.get(env, "").lower() in ("true", "1"):
            return True
    return False


def validate_rumdl_config() -> None:
    """Schema-validate .rumdl.toml against rumdl's published config schema, fetched at the
    installed rumdl version's tag (pin: mise.toml [tools] + mise.lock). Requires rumdl on
    PATH (`mise run validate`)."""
    import jsonschema

    config_file = ROOT / ".rumdl.toml"
    if not config_file.is_file():
        return
    config = tomllib.loads(config_file.read_text())

    try:
        out = subprocess.run(
            ["rumdl", "--version"], capture_output=True, text=True, check=True
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        sys.exit("rumdl not on PATH: run this task via `mise run validate`")
    version = out.split()[-1]

    schema_url = f"https://raw.githubusercontent.com/rvben/rumdl/v{version}/rumdl.schema.json"
    schema_file = CACHE.parent / f"rumdl-schema-v{version}.json"
    if not schema_file.is_file():
        schema_file.parent.mkdir(parents=True, exist_ok=True)
        print(f"fetching {schema_url}")
        schema_file.write_text(urllib.request.urlopen(schema_url).read().decode())
    try:
        jsonschema.validate(config, json.loads(schema_file.read_text()))
    except jsonschema.ValidationError as err:
        loc = "/".join(str(p) for p in err.absolute_path) or "<root>"
        fail(".rumdl.toml", f"schema mismatch at {loc}: {err.message[:200]}")
    except jsonschema.SchemaError as err:
        fail(".rumdl.toml", f"fetched schema unusable: {err.message[:200]}")


def validate_rumdl_no_autofix() -> None:
    """Behavioral canary: rumdl must not rewrite ANY file (panache owns all markdown
    formatting). Runs `rumdl fmt` on a scratch violation file with the repo config and fails if
    it changed - a rumdl upgrade that flips the inert-`all` fixable semantics (see the comment in
    .rumdl.toml) is caught at `mise run check`. Requires rumdl on PATH (`mise run validate`)."""
    canary = "# canary\n\nSome  text with fixable issues.   \n\n- item one\n+ item two\nTab\there\n"
    with tempfile.TemporaryDirectory() as td:
        canary_file = pathlib.Path(td) / "canary.md"
        canary_file.write_text(canary)
        try:
            subprocess.run(
                ["rumdl", "fmt", "--config", str(ROOT / ".rumdl.toml"), str(canary_file)],
                capture_output=True,
                text=True,
                check=True,
            )
        except FileNotFoundError:
            sys.exit("rumdl not on PATH: run this task via `mise run validate`")
        except subprocess.CalledProcessError as err:
            fail(".rumdl.toml", f"canary fmt invocation failed: {err.stderr[-200:]}")
            return
        if canary_file.read_text() != canary:
            fail(
                ".rumdl.toml",
                "rumdl fmt rewrote a canary file: rumdl's autofix must stay"
                " disabled (panache owns formatting; see the fixable comment"
                " in .rumdl.toml) - re-verify the installed rumdl version's"
                " fixable/unfixable semantics",
            )


def validate_panache_config() -> None:
    """Schema-validate .panache.toml against panache's published config schema, fetched at the
    installed panache version's tag (pin: mise.toml [tools] + mise.lock) - same pattern as rumdl.
    Requires panache on PATH (`mise run validate`)."""
    import jsonschema

    config_file = ROOT / ".panache.toml"
    if not config_file.is_file():
        return
    config = tomllib.loads(config_file.read_text())

    try:
        version = (
            subprocess.run(
                ["panache", "--version"], capture_output=True, text=True, check=True
            )
            .stdout.strip()
            .split()[-1]
        )
    except (OSError, subprocess.CalledProcessError):
        sys.exit("panache not on PATH: run this task via `mise run validate`")

    schema_url = f"https://raw.githubusercontent.com/jolars/panache/v{version}/panache.schema.json"
    schema_file = CACHE.parent / f"panache-schema-v{version}.json"
    if not schema_file.is_file():
        schema_file.parent.mkdir(parents=True, exist_ok=True)
        print(f"fetching {schema_url}")
        schema_file.write_text(urllib.request.urlopen(schema_url).read().decode())
    try:
        jsonschema.validate(config, json.loads(schema_file.read_text()))
    except jsonschema.ValidationError as err:
        loc = "/".join(str(p) for p in err.absolute_path) or "<root>"
        fail(".panache.toml", f"schema mismatch at {loc}: {err.message[:200]}")
    except jsonschema.SchemaError as err:
        fail(".panache.toml", f"fetched schema unusable: {err.message[:200]}")


APKINDEX_TTL = 24 * 3600  # the daily CI cron should see Alpine-side repoints


def _apkindex_versions(branch: str, package: str) -> dict[str, str]:
    """Version of <package> in the Alpine v<branch> binary indexes, per arch - the BINARY index
    (dl-cdn APKINDEX) is what `apk add` resolves, not the aports APKBUILD source branch (a pkgrel
    commit can outrun the published packages; policy: root KNOWLEDGE.md §apk package version
    policy). Cached for APKINDEX_TTL so local runs stay snappy while the daily cron sees fresh data."""
    versions: dict[str, str] = {}
    for arch in ("x86_64", "aarch64"):
        dest = CACHE.parent / f"apkindex-v{branch}-{arch}"
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


def validate_apk_pins() -> None:
    """Verify apk package version pins in app Dockerfiles against the Alpine binary indexes of
    the pinned base-image branch (policy + why: root KNOWLEDGE.md §apk package version policy)."""
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
            found = re.findall(
                r"([A-Za-z0-9][\w.+-]*)=(\d[\w.:]+(?:-r\d+)?)", raw
            )
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


def main() -> int:
    global CONST_NAMES
    if _flag("schemas-only"):
        print("-- refetching pinned supervisor schemas (invalidating the cache)")
        shutil.rmtree(CACHE, ignore_errors=True)
    # needed ATTR_* names: grep the schemas first, then fetch their values
    schema_src = extract("supervisor/apps/validate.py", SCHEMA_NAMES)
    aa_src = extract("supervisor/utils/apparmor.py", APPARMOR_RE_NAME)
    CONST_NAMES = set()
    for src in (*schema_src.values(), *aa_src.values()):
        for node in ast.walk(ast.parse(src)):
            if isinstance(node, ast.Name) and node.id.startswith("ATTR_"):
                CONST_NAMES.add(node.id)

    if _flag("schemas-only"):
        return 0  # cache warmed by the fetches above
    validate_rumdl_config()
    validate_rumdl_no_autofix()
    validate_panache_config()
    validate_apk_pins()

    for app in find_apps():
        app_dir = ROOT / app
        config_file = next(
            (f for f in (app_dir / "config.yaml", app_dir / "config.yml") if f.is_file()),
            None,
        )
        if not config_file:
            fail(app, "no config.yaml/config.yml")
            continue
        try:
            config = yaml.safe_load(config_file.read_text())
        except yaml.YAMLError as err:
            fail(app, f"config file does not parse: {err}")
            continue
        for key in ("name", "version", "slug", "description", "arch"):
            if key not in config:
                fail(app, f"required config key '{key}' missing")

        translations = {}
        translations_dir = app_dir / "translations"
        if translations_dir.is_dir():
            for tf in sorted(translations_dir.iterdir()):
                if tf.suffix not in (".yaml", ".yml", ".json"):
                    continue
                try:
                    data = (
                        yaml.safe_load(tf.read_text())
                        if tf.suffix != ".json"
                        else json.loads(tf.read_text())
                    )
                except Exception as err:
                    fail(app, f"{tf.name} does not parse: {err}")
                    continue
                ns: dict[str, object] = {"vol": voluptuous, **supervisor_constants()}
                ns["SCHEMA_TRANSLATION_CONFIGURATION"] = eval(  # noqa: S307
                    schema_src["SCHEMA_TRANSLATION_CONFIGURATION"], ns
                )
                schema = eval(  # noqa: S307
                    schema_src["SCHEMA_APP_TRANSLATIONS"], ns
                )
                try:
                    translations[tf.stem] = schema(data)
                except voluptuous.Invalid as err:
                    fail(app, f"{tf.name} fails supervisor schema: {err}")

        # cross-checks
        ports = set((config.get("ports") or {}).keys())
        for lang, data in translations.items():
            net = data.get("network") or {}
            wrong = set(net.keys()) - ports
            if wrong:
                fail(
                    app,
                    f"translations[{lang}].network keys not in config.yaml ports "
                    f"(case-sensitive, lowercase!): {sorted(wrong)}",
                )
            for opt, sub in (data.get("configuration") or {}).items():
                fields = sub.get("fields") or {}
                schema = config.get("schema") or {}
                entry = schema.get(opt)
                is_list_of_objects = isinstance(entry, list)
                if fields and not is_list_of_objects:
                    fail(app, f"translations[{lang}].configuration.{opt} has fields but schema entry is not a list-of-objects")
                if not fields and is_list_of_objects:
                    fail(app, f"translations[{lang}].configuration.{opt} misses fields for list-of-objects schema entry")
                if fields and is_list_of_objects:
                    sub_keys = set((schema.get(opt) or [{}])[0].keys())
                    missing = set(fields.keys()) - sub_keys
                    if missing:
                        fail(app, f"translations[{lang}].configuration.{opt}.fields keys not in schema: {sorted(missing)}")

        aa_file = app_dir / "apparmor.txt"
        # (the apparmor key's presence itself is checked by the CI app linter)
        if aa_file.is_file():
            ns: dict[str, object] = {"re": __import__("re")}
            regex = eval(aa_src["RE_PROFILE"], ns)  # noqa: S307
            profile_names = [
                m.group(1) for line in aa_file.read_text().splitlines()
                if (m := regex.match(line))
            ]
            if len(profile_names) != 1:
                fail(
                    app,
                    f"apparmor.txt must contain exactly one top-level profile "
                    f"(indent sub-profiles!), found {len(profile_names)}: {profile_names}",
                )
            slug = config.get("slug")
            if slug and profile_names and profile_names[0] != slug:
                # supervisor renames the profile to the installed slug anyway;
                # matching the config slug keeps the file self-documenting
                print(f"[{app}] note: profile name '{profile_names[0]}' != slug '{slug}' (supervisor adjusts it)")

    if problems:
        print("\nVALIDATION FAILED:")
        for p in problems:
            print(f"  {p}")
        return 1
    print("validate OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
