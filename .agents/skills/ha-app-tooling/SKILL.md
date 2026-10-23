---
name: ha-app-tooling
description: How this repository's dev tooling works — the hk lint gate and git hooks, mise task authoring with usage
  specs, what validate.py checks, and the YAML/shell linting conventions. Use when touching hk.pkl, mise tasks, or lint
  configuration, or when interpreting lint failures.
---

# Dev tooling (hk, mise tasks, validate.py, linting)

**Task usage is not documented here**: `mise run <task> --help` is the authoritative, always-current usage for every
task (args, flags, choices). This skill covers only the conventions and gotchas behind the tasks.

## Lint gate (hk)

- `mise run check` — lint plus validate; **always run before finishing a change**. CI's `check` job and `mise run lint`
  run `hk check --all` over every tracked file; plain `hk check` lints only modified files (fast local feedback).
  Untracked files are never selected (verified for hk 2.7.1, `check` and `--all` alike, independent of HK_STASH
  settings); `env.HK_STASH_UNTRACKED=0` in mise.toml additionally keeps untracked worktree files out of the pre-commit
  stash/restore cycle and skips their discovery.
- To check an explicit file set, pipe NUL-separated paths to hk:
  `git diff --name-only -z HEAD | hk check --files0-from=-`.
- Git hooks (enable once per machine: `mise run install-git-hooks`, after `mise install --locked`; needs Git 2.54+,
  installs user-wide, silently no-ops in repos without `hk.pkl`): pre-commit auto-fixes (panache format, final newlines,
  shfmt, shellcheck autofixes) and gates the commit; commit-msg enforces Conventional Commits. Escape hatch:
  `HK=0 git commit`.

## mise task authoring

- File tasks live in `.mise/tasks/` with proper suffixes (`.sh`, `.py`, … — mise resolves the short names, e.g.
  `mise run lint`) and `#MISE`/`#USAGE` header comments.
- Document and type task arguments via usage specs — never bare `$1` handling unless `raw_args = true`.
- Required args: declare `arg "<name>"` — mise errors before the task starts when missing (no manual checks). Read with
  `${usage_name?}`; optional ones with `${usage_name:-…}` defaults; boolean flags with `${usage_name:-false}` (mise
  docs, "Read argument values"). In Python tasks the values are exported as `usage_<underscored_name>` env vars.

## validate.py (`.mise/tasks/validate.py`, part of `mise run check`)

- Fetches supervisor schemas from the ref pinned in `mise.toml` `[vars].supervisor_ref` (cached under `~/.cache/`).
- Renovate bumps that pin to the newest supervisor release and automerges the bump once CI `check` is green (rebase
  merge strategy, `.github/renovate.json`) — green means the new schemas validate our app configs. Renovate does not
  track schema-*behavior* changes: re-verify version-sensitive supervisor facts against the new ref before relying on
  them (skill `ha-app-workflow`).
- Schema-validates `.rumdl.toml` against rumdl's and `.panache.toml` against panache's published config schemas, and
  compares pinned apk package versions in app Dockerfiles against the Alpine binary indexes (drift = guided release —
  root `KNOWLEDGE.md` §"apk package version policy"). `.github/renovate.json` is gated by the official
  `renovate-config-validator` hk step instead (see the linting section below).

## YAML linting: ryl

- YAML is linted by ryl (hk `ryl` step, config `.ryl.toml`, pinned as `aqua:owenlamont/ryl` in mise.toml).
- ryl parses YAML 1.2; yamllint defaulted to 1.1: bareword booleans (`yes`/`no`/`on`/`off`, any case) are plain strings
  and leading-zero integers like `0755` are decimal — while YAML 1.1 parsers (PyYAML and kin) still coerce both. Do not
  predict what a parser will load from ryl's lint view.
- The hk step runs `ryl check --strict` (`--strict` added to both `check` and `fix`): warning-level rules (line-length,
  comments, document-start, truthy — see `.ryl.toml`) fail the gate like errors (warning-only runs exit `2`, errors
  `1`). The builtin's fix step auto-fixes mechanical issues (braces/brackets/commas spacing, comment spacing, final
  newline, quoting) in pre-commit.
- The builtin's `check_diff` wiring is cleared (`check_diff = null`, `check_after_diff = false`): ryl's `--diff` exit
  code only reflects patch presence — it exits `0` whenever nothing is fixable, including files with unfixable warnings
  or errors — and hk's fix mode skips the fixer when `check_diff` exits `0`, so violating files would pass pre-commit
  untouched. With `check_diff` gone, fix mode runs `fix` (carrying `--strict`) on every staged YAML file and its exit
  code decides: `0` only when nothing remains to fix or flag. (Upstream issue: root `TODO.md`.)
- `line-length` ignores comments by default (yamllint parity): the 140 limit bites YAML scalars only.
- Config is TOML with `[lint.rules]` (`[rules]` is deprecated as of ryl 0.26). A rule with an option table must not also
  appear as a `"<name>" = "enable"` string in the same table — TOML duplicate key, ryl exits `2` loudly.

## Shell linting

- shfmt (formatting; follows .editorconfig) and shellharden (quoting hardening) are hk *fix* steps — let pre-commit fix
  or run `hk check --fix` instead of hand-formatting; shellcheck `-x` is the lint gate.
- The shfmt style (binary-next-line, indented case) is pinned under `.editorconfig`'s `[**]`, whose `root = true` stops
  EditorConfig discovery at the repo — without it a home-directory config silently defines the style locally and CI sees
  shfmt defaults instead.
- shellharden quotes command substitutions even where word splitting is required (for-loop iterables) — write such loops
  as brace expansion (`for _ in {1..N}`) or arrays (`read -r -a` / `mapfile`) instead. It also quotes command-string
  executions (`if "$NFSD_CMD"`) where quoting changes what is *executed*: the whole string becomes one literal command
  name (`command not found` — this broke nfs-server 0.6.1 on-device). Build such commands as arrays
  (`NFSD_CMD=(...); "${NFSD_CMD[@]}"`) so quoting is stable either way. (Upstream items: root `TODO.md`.)

## Workflow, Dockerfile and Renovate config linting

- GitHub workflows, composite actions and Dependabot config: jactionlint (hk builtin; the maintained actionlint fork,
  <https://jactionlint.jdx.dev/>) plus zizmor's security audits. jactionlint auto-reads `.github/jactionlint.yaml` —
  profile `default` = actionlint's correctness checks plus the zizmor-parity regular-persona rules (`pedantic` adds
  auditor-persona noise); it replicates every zizmor audit as a same-ID rule, so the gate runs both deliberately: zizmor
  keeps what jactionlint lacks (confidence grading, pre-commit/repo-slug auditing, LSP mode, its own zizmor.yml config)
  and jactionlint's parity target lags zizmor releases. Its `unpinned-uses` policy and `.github/zizmor.yml` mirror
  `.github/renovate.json`: `home-assistant/*` may float on a branch (the home-assistant org's actions), everything else
  must be digest-pinned — keep all three in sync when adding actions.
- The hk `zizmor` step runs `zizmor -qq --no-progress`; `-qq` trims zizmor's tracing noise (version banner, per-file
  completion notices, the offline-mode notice and the YAML-anchors beta notice - anchors are used by design). Findings
  render regardless of verbosity, so the gate's verdict is unaffected. Its mode follows the environment: a
  `GH_TOKEN`/`GITHUB_TOKEN`/ `ZIZMOR_GITHUB_TOKEN` enables zizmor's four online-only audits (impostor-commit,
  known-vulnerable-actions, ref-confusion, stale-action-refs), without one the audit is fully offline. CI passes its
  default `GITHUB_TOKEN` for the strongest audit; locally the gate stays offline unless a token is exported (opt out
  with `ZIZMOR_NO_ONLINE_AUDITS=1`). Online results depend on remote state: a once-green run can go red when, e.g., a
  security advisory lands for a pinned action - that is signal; re-run or fix forward. zizmor caches API responses
  (~/.cache/zizmor), so a local run shortly after another can reuse them. A finding that must stay (a checkout whose
  later step pushes, e.g. apk-bump's changelog job) carries an inline `# zizmor: ignore[<audit-id>]` comment stating the
  reason.
- Local `uses:` references use GitHub's self-repository syntax (`$/.github/workflows/…`), not `./`: `$/` resolves the
  reference from the running commit by construction, so it counts as digest-pinned (zizmor `self-repository` audit;
  needs runner 2.336.0+).
- Dockerfiles: droast (hadolint-compatible CLI, <https://github.com/immanuwell/dockerfile-roast>; hk builtin) with
  project-level skips in `droast.toml` (DF020/DF036 — the HA base image provides the runtime identity and init via
  s6-overlay; DF033 — no per-app `.dockerignore`, root `TODO.md`). Rule IDs are `DF0xx`; a `# hadolint ignore=DLxxx`
  pragma is dead weight under droast — inline ignores are `# droast ignore=DFxxx reason="…"`, and
  `droast --hadolint-compatible --hadolint-compatibility-report` maps old DL IDs to their DF equivalents.
- `.github/renovate.json` is validated by the official `renovate-config-validator` via a custom hk step
  (`--no-global --strict`). `--no-global` matters: bare file args are otherwise validated as a GLOBAL self-hosted
  config, which a repo config is not. `--strict` also fails while the installed Renovate flags a pending config
  migration, so Renovate bumps that deprecate config keys surface immediately. The validator's RE2→RegExp fallback
  (native `re2` module absent — the aube npm backend installs without lifecycle scripts) prints a verbose stack trace on
  every run: expected noise, non-fatal (our regexes are RE2-safe; root `TODO.md`).
- Renovate also manages the mise.toml `[tools]` pins (manager `mise`; weekly, Monday, like the other managers) and keeps
  `mise.lock` in sync — except `hk`, whose binary pin and the `hk@X.Y.Z` package imported by `hk.pkl` must move together
  in one manual change (excluded via packageRule in `.github/renovate.json`).

## bashio shebang note

Scripts with the `#!/usr/bin/with-contenv bashio` shebang are plain bash, but hk's shebang-based file typing does not
recognize the wrapper (root `TODO.md`), so `hk.pkl` re-declares each shell builtin's `match_any` with added glob
selectors for the s6 script paths — keep those globs when adding app scripts.
