---
name: ha-app-tooling
description: How this repository's dev tooling works — the hk lint gate and git hooks, mise task authoring with usage
  specs, what the validate tasks check, and the YAML/shell/TOML linting conventions. Use when touching hk.pkl, mise tasks, or lint
  configuration, or when interpreting lint failures.
---

# Dev tooling (hk, mise tasks, validation, linting)

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
  installs user-wide, silently no-ops in repos without `hk.pkl`): pre-commit auto-fixes (panache format, tombi format,
  final newlines, shfmt, shellcheck autofixes) and gates the commit; commit-msg enforces Conventional Commits. Escape
  hatch: `HK=0 git commit`.

## mise task authoring

- File tasks live in `.mise/tasks/` with proper suffixes (`.sh`, `.py`, … — mise resolves the short names, e.g.
  `mise run lint`) and `#MISE`/`#USAGE` header comments.
- Document and type task arguments via usage specs — never bare `$1` handling unless `raw_args = true`.
- Required args: declare `arg "<name>"` — mise errors before the task starts when missing (no manual checks). Read
  required string args with `${usage_name:?}` — it also rejects empty values, which pass mise's presence check (mise
  docs, "Read argument values": `?` errors only when unset, `:?` also when empty). Optional args read with
  `${usage_name:-…}` (empty ≡ unset); boolean flags with `${usage_name:-false}`, compared against `"true"`. In Python
  tasks the values are exported as `usage_<underscored_name>` env vars — reject empty required values explicitly there
  (the `:?` guard is shell-only).

## validate:apps (`.mise/tasks/validate/apps.py`, part of `mise run check`)

- Fetches supervisor schemas from the ref pinned in `mise.toml` `[vars].supervisor_ref` (cached under `~/.cache/`).
- Renovate bumps that pin to the newest supervisor release and automerges the bump once CI `check` is green (rebase
  merge strategy, `.github/renovate.json`) — green means the new schemas validate our app configs. Renovate does not
  track schema-*behavior* changes: re-verify version-sensitive supervisor facts against the new ref before relying on
  them (skill `ha-app-workflow`).
- apk pin drift is a separate task: `mise run validate:apk-pins` (`.mise/tasks/validate/apk-pins.py`) compares pinned
  apk package versions in app Dockerfiles against the Alpine binary indexes (drift = guided release — root
  `KNOWLEDGE.md` §"apk package version policy"); CI runs it only on main pushes and the daily cron (lint workflow),
  never in the PR gate — the indexes are Alpine's publishing state, not the PR's. TOML config schemas are validated by
  the hk `tombi-lint` step instead (section below); `.github/renovate.json` is gated by the official
  renovate-config-validator hk step (see the linting section below).

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

## TOML linting: tombi

- TOML is linted and formatted by tombi (hk builtins `tombi`/`tombi_format`, pinned as `tombi` in mise.toml);
  `mise run fmt` formats via `tombi format .`. The lint step adds `--error-on-warnings`: tombi exits 0 when only its
  warn-severity rules fire, and the gate must fail on them (its three built-ins — key-empty, dotted-keys-out-of-order,
  tables-out-of-order — are all warn-severity).
- Schemas bind per-file via a `#:schema <url>` top directive (Taplo-compatible; must be the document's first comment,
  followed by a blank line). Renovate auto-bumps our tools, so "latest" is usually the right schema ref. The repo-level
  `.tombi.toml` config file defines the TOML formatting rules (only deviations from tombi's defaults,
  <https://tombi-toml.github.io/tombi/docs/configuration>).
- tombi validates in **strict mode** (default): objects without `additionalProperties` are treated as closed, so unknown
  keys are errors even when the schema doesn't mark them so — stricter than the stock-JSON-Schema validation
  `validate:apps` performs on the supervisor schemas. Adding a config key the upstream schema doesn't know yet fails the
  gate until the schema learns it: the schema is the contract. Schema deprecations are warn-severity, hence gate-failing
  too.
- Schemas are fetched remotely and cached (`~/.cache/tombi`, 24 h TTL; `tombi cache clean`). Offline runs reuse cached
  copies and silently skip un-cached schemas, while CI always runs online — schema checks therefore track upstream
  main/latest, not the installed tool version, and an upstream schema change can fail the gate with no local change
  (signal, like zizmor's online audits).
- Formatter defaults match .editorconfig (2-space, LF, double quotes) and nothing is key-sorted by default; an
  unformatted file is an Error (exit 1) in the format check.

## Python linting: ruff

- Python (the `.mise/tasks/` scripts) is linted and formatted by ruff via the hk builtins `ruff` (check/fix =
  `ruff check`; the fix path preflights with the builtin's `check_diff`) and `ruff_format` (check via
  `ruff format --diff`, fix via `ruff format`), pinned as `aqua:astral-sh/ruff` in mise.toml. The formatter step runs
  before the linter step; `mise run fmt` runs `ruff format .`.
- Config is `.ruff.toml` (TOML, `#:schema`-bound): the rule selection is pinned explicitly there (don't swap `select`
  for `extend-select`) because ruff 0.17.0 expanded the default rule set and keeps drifting with releases (ruff
  CHANGELOG 0.17.0, astral-sh/ruff#28786) — the gate must not move with upstream defaults. `target-version` stays
  unpinned: it is inert for the selected rules and nothing couples it to the `python` mise.toml pin, so a pin would
  drift (ruff's own default applies). Note that UP is target-sensitive in the other direction: once ruff's default
  target crosses py314, its safe autofix will drop the no-longer-needed `from __future__ import annotations` imports.
- ruff does not read `.editorconfig`; its formatter defaults (4-space indent, double quotes, 88 columns) match this
  repo's Python style. Both builtins pass `--force-exclude`, so config excludes apply even to hk's explicit file
  arguments, and ruff resolves the config by walking up from each target file — the root `.ruff.toml` covers every task
  script.
- The `#MISE`/`#USAGE` task directives sit inside `# fmt: off`/`# fmt: on` markers in every task script: ruff format
  normalizes `#MISE` comment spacing (no comment-prefix exclusion exists) and must not touch them. mise's parser
  tolerates the spaced form (its prefix regexes match with `\s*` tolerance, unlike the usage crate's strict `#USAGE`
  regex; mise `src/task/mod.rs`, verified 2026-11-12 against mise 2026.11.6), but the unspaced directives stay canonical
  — keep the markers around the block, and never append anything to directive lines (the header parses as TOML).

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
  (`NFSD_CMD=(...); "${NFSD_CMD[@]}"`) so quoting is stable either way. Its parser also loses sync on nested parentheses
  inside arithmetic expansion (`"$(( (a << 8) | b ))"` reports "the parser got lost" on a syntactically complete file
  and mangles everything after it — spurious `""` prefixes, quotes inserted into single-quoted strings); keep arithmetic
  flat, flat `$(( 10#$a ))` is fine — and even flat, avoid `<<` in arithmetic (lexed as a heredoc delimiter, same loss
  of sync; write it out: `$((5 * 2 ** attempt))`). (Upstream items: root `TODO.md`.)

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
  s6-overlay). Rule IDs are `DF0xx`; a `# hadolint ignore=DLxxx` pragma is dead weight under droast — inline ignores are
  `# droast ignore=DFxxx reason="…"`, and `droast --hadolint-compatible --hadolint-compatibility-report` maps old DL IDs
  to their DF equivalents.
- `.github/renovate.json` is validated by the official `renovate-config-validator` via a custom hk step
  (`--no-global --strict`). `--no-global` matters: bare file args are otherwise validated as a GLOBAL self-hosted
  config, which a repo config is not. `--strict` also fails while the installed Renovate flags a pending config
  migration, so Renovate bumps that deprecate config keys surface immediately.
- Renovate also manages the mise.toml `[tools]` pins (manager `mise`; weekly, Monday, like the other managers) and keeps
  `mise.lock` in sync — including `hk`: a custom regex manager (`.github/renovate.json`) rewrites the `hk@X.Y.Z` package
  imports in `hk.pkl` with the same depName/datasource/currentValue as the mise manager's hk dep, so both land in one
  branch and one PR bumps all three files. Manual bumps use `mise run bump-hk <version>`; the CI check catches partial
  desyncs (`mise install --locked` errors on a mise.toml/mise.lock disagreement).

## bashio shebang note

Scripts with the `#!/usr/bin/with-contenv bashio` shebang are plain bash, but hk's shebang-based file typing does not
recognize the wrapper (root `TODO.md`), so `hk.pkl` re-declares each shell builtin's `match_any` with added glob
selectors for the s6 script paths and the apps' `/usr/bin` scripts — keep those globs when adding app scripts.
