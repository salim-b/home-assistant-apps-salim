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
  run `hk check --all` over every tracked file; plain `hk check` lints only modified files (fast local feedback;
  untracked files are never selected — `env.HK_STASH_UNTRACKED=0` in mise.toml).
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
- Also schema-validates `.github/renovate.json` against the published Renovate config schema (refetched whenever that
  file changes), `.rumdl.toml` against rumdl's and `.panache.toml` against panache's config schema, and compares pinned
  apk package versions in app Dockerfiles against the Alpine binary indexes (drift = guided release — root
  `KNOWLEDGE.md`, section "apk package version policy").

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

## bashio shebang note

Scripts with the `#!/usr/bin/with-contenv bashio` shebang are plain bash, but hk's shebang-based file typing does not
recognize the wrapper (root `TODO.md`), so `hk.pkl` re-declares each shell builtin's `match_any` with added glob
selectors for the s6 script paths — keep those globs when adding app scripts.
