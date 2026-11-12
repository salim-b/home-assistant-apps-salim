#!/usr/bin/env -S uv run --with voluptuous --with pyyaml python3
# fmt: off
#MISE description="Validate app configs and translations against HA Supervisor schemas"
#USAGE arg "[app]" help="App directory to validate (default: all apps)"
#USAGE flag "--schemas-only" help="Only refetch the pinned Supervisor schemas"
# fmt: on

"""validate:apps: supervisor-side validation the CI app linter does not cover.

Runs against a pinned supervisor ref (what each check is for: .agents/skills/ha-app-tooling).
Parses all app YAML files (catching parse errors early); validates translations against the
supervisor's voluptuous schemas (AST-extracted from the pinned ref - no drifting copies) and the
AppArmor profile against the supervisor's profile-name regex (exactly one top-level profile);
cross-checks translation 'configuration' keys vs schema keys (incl. nested 'fields') and
'network' keys (lowercase!) vs config.yaml 'ports'; canary-checks that rumdl's
autofix stays disabled (panache owns formatting; see .rumdl.toml `fixable`).
TOML config schemas (.rumdl.toml, .panache.toml, mise.toml) are validated by the hk `tombi`
step instead, via the files' `#:schema` directives (.agents/skills/ha-app-tooling).
"""

from __future__ import annotations

import ast
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
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

        with (ROOT / "mise.toml").open("rb") as f:
            return tomllib.load(f)["vars"]["supervisor_ref"]
    except Exception:  # noqa: BLE001 - fail-fast: exit with a message on any error
        sys.exit("cannot determine supervisor ref (mise.toml [vars].supervisor_ref)")


REF = _supervisor_ref()
RAW = "https://raw.githubusercontent.com/home-assistant/supervisor"
CACHE = (
    pathlib.Path(os.environ.get("XDG_CACHE_HOME", pathlib.Path.home() / ".cache"))
    / "ha-apps-supervisor-schemas"
    / REF
)

# supervisor.const ATTR_* names the schemas reference; fetched from const.py at the pinned ref
CONST_NAMES: set[str] = set()
SCHEMA_NAMES = ("SCHEMA_TRANSLATION_CONFIGURATION", "SCHEMA_APP_TRANSLATIONS")
APPARMOR_RE_NAME = "RE_PROFILE"


def fetch(name: str) -> str:
    """The cached supervisor schema file content for name (fetched from the pinned ref on miss)."""
    dest = CACHE / name
    if dest.is_file():
        return dest.read_text()
    dest.parent.mkdir(parents=True, exist_ok=True)
    url = f"{RAW}/{REF}/{name}"
    print(f"fetching {url}")
    dest.write_text(urllib.request.urlopen(url).read().decode())  # noqa: S310 - pinned supervisor ref, https only
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
    """The apps to validate: the optional [app] arg, or all app dirs.

    `usage_app` env var (mise) or first argv token (direct runs); empty/unset means all apps,
    like the optional arg's shell `:-` expansion (empty ≡ unset).
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


problems: list[str] = []


def fail(app: str, msg: str) -> None:
    """Record a problem for app (printed at exit with a nonzero status)."""
    problems.append(f"[{app}] {msg}")


def _flag(name: str) -> bool:
    """Read a mise #USAGE boolean flag (exposed to the task as env vars)."""
    for env in (f"usage_{name.replace('-', '_')}", name.upper().replace("-", "_")):
        if os.environ.get(env, "").lower() in ("true", "1"):
            return True
    return False


def validate_rumdl_no_autofix() -> None:
    """Behavioral canary: rumdl must not rewrite ANY file (panache owns all markdown formatting).

    Runs `rumdl fmt` on a scratch violation file with the repo config and fails if it changed - a
    it changed - a rumdl upgrade that flips the inert-`all` fixable semantics (see the comment in
    .rumdl.toml) is caught at `mise run check`. Requires rumdl on PATH (`mise run validate:apps`).
    """
    canary = "# canary\n\nSome  text with fixable issues.   \n\n- item one\n+ item two\nTab\there\n"
    with tempfile.TemporaryDirectory() as td:
        canary_file = pathlib.Path(td) / "canary.md"
        canary_file.write_text(canary)
        try:
            subprocess.run(  # noqa: S603 - fixed argument list, no untrusted input
                [  # noqa: S607 - rumdl resolves via mise-managed PATH
                    "rumdl",
                    "fmt",
                    "--config",
                    str(ROOT / ".rumdl.toml"),
                    str(canary_file),
                ],
                capture_output=True,
                text=True,
                check=True,
            )
        except FileNotFoundError:
            sys.exit("rumdl not on PATH: run this task via `mise run validate:apps`")
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


def main() -> int:
    """Run every check for the selected apps (or refetch the pinned schemas with --schemas-only)."""
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
    validate_rumdl_no_autofix()

    for app in find_apps():
        app_dir = ROOT / app
        config_file = next(
            (
                f
                for f in (app_dir / "config.yaml", app_dir / "config.yml")
                if f.is_file()
            ),
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
                except Exception as err:  # noqa: BLE001 - report any read/parse error, skip the file
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
                # A list schema entry is list-of-objects only when its item spec is a mapping; a scalar item
                # (`- "str"`) is a list-of-strings, which has no fields (official apps: Let's Encrypt `domains`).
                is_list_of_objects = (
                    isinstance(entry, list)
                    and bool(entry)
                    and isinstance(entry[0], dict)
                )
                if fields and not is_list_of_objects:
                    fail(
                        app,
                        f"translations[{lang}].configuration.{opt} has fields but schema is not a list-of-objects",
                    )
                if not fields and is_list_of_objects:
                    fail(
                        app,
                        f"translations[{lang}].configuration.{opt} misses fields for list-of-objects schema entry",
                    )
                if fields and is_list_of_objects:
                    sub_keys = set((schema.get(opt) or [{}])[0].keys())
                    missing = set(fields.keys()) - sub_keys
                    if missing:
                        fail(
                            app,
                            f"translations[{lang}].configuration.{opt}.fields keys not in schema: {sorted(missing)}",
                        )

        aa_file = app_dir / "apparmor.txt"
        # (the apparmor key's presence itself is checked by the CI app linter)
        if aa_file.is_file():
            ns: dict[str, object] = {"re": __import__("re")}
            regex = eval(aa_src["RE_PROFILE"], ns)  # noqa: S307
            profile_names = [
                m.group(1)
                for line in aa_file.read_text().splitlines()
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
                print(
                    f"[{app}] note: profile name '{profile_names[0]}' != slug '{slug}' (supervisor adjusts it)"
                )

    if problems:
        print("\nVALIDATION FAILED:")
        for p in problems:
            print(f"  {p}")
        return 1
    print("validate:apps OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
