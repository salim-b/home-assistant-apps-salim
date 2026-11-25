# TODOs

Cross-app work items (tooling, CI, harnesses); app-specific items live in each app's `TODO.md`. Underlying technical
facts live in the repository-root `KNOWLEDGE.md`; procedures in the skills under `.agents/skills/`.

## Tasks

- Flip the AI supply-chain review from shadow to gating (skill/citation: root `KNOWLEDGE.md` §"CI: AI supply-chain
  review of action bumps", §"CI: Branch protection and platform-native automerge"): once
  `.github/workflows/action-bump-review.yaml` verdicts have been validated over a few real Renovate action bumps
  (`.github/renovate.json` package rules), make the review check a required context and set `automerge: true`
  (minor/patch, rebase strategy) for `tj-actions/changed-files` and `nick-fields/retry`. Under platform-native automerge
  the merge gate is the branch protection required-check set alone – the review job's conclusion blocks a merge only as
  a required context, and required contexts must report on every PR, so the flip needs the review job to run-and-report
  unconditionally (internal no-op skip for PRs without a reviewable action bump) instead of its current `paths:` filter.
  Preconditions: the review job's hardening fixes are on `main` (fork pull requests skipped; the tamper guard covers the
  verdict scripts and the mise toolset) and a dispatch run has exercised the pipeline end-to-end. Digest-typed updates
  (a ref repointed without a release) stay manual regardless: release-age gates cannot soak them (github-tags timestamps
  age against the original release) and they are the highest-signal event for human review.

- Upstream: file an hk issue/PR against [jdx/hk](https://github.com/jdx/hk) – its shebang-based file typing (v2.7.0,
  `src/file_type.rs`) does not recognize `#!/usr/bin/with-contenv bashio` (the Home Assistant base image's interpreter
  for s6-overlay scripts): wrapper interpreter plus unknown `bashio` argument resolve to plain text, so hk's
  shellcheck/shfmt/shellharden builtins (types `sh`/`bash`) silently skip every app script. Desired: look through
  s6-overlay's `with-contenv` (and similar env-style wrappers) to the real interpreter and type `bashio` as shell – the
  file content is plain bash. Until then, `hk.pkl` re-declares each shell builtin's `match_any` with added glob
  selectors for the s6 script paths (see the `s6Globs` comment there); the glob additions can be dropped once this
  lands. All three shell steps also cover the apps' `/usr/bin` scripts via the `appBinGlobs` selector.

- Upstream: file an hk issue against [jdx/hk](https://github.com/jdx/hk) (likely co-filed with
  [owenlamont/ryl](https://github.com/owenlamont/ryl)) – the `ryl` builtin's fix-mode wiring silently passes files with
  unfixable violations. hk's fix mode runs `check_diff` first and skips the fixer when it exits 0; ryl 0.26.0's `--diff`
  exit code reflects only patch presence: it exits 0 whenever nothing is fixable – including files carrying unfixable
  warnings or errors (probed 2026-10-20: `ryl check --diff` on a duplicate-key error file exits 0, and `--strict` does
  not change `--diff` exit codes; a fixable brace-spacing file prints the patch and exits 1). With the builtin as
  shipped (hk v2.7.0 `pkl/builtins/ryl.pkl`: `check_diff = ryl check --diff {{files}}`, `check_after_diff = true`),
  every pre-commit run (fix mode) passes files that `hk check --all` fails – the `check_after_diff` recheck never fires
  because no diff was applied. hk's own builtin test misses this: `testMaker.fixFail` exercises the fix command
  directly, not the check_diff-first flow the hook actually takes. Investigate which side should own the fix: ryl
  exiting non-zero from `--diff` when diagnostics exist without fixes, or hk not treating `check_diff` exit 0 as "clean"
  for partial fixers (e.g. re-running `check` when the fixer is skipped). Until then, this repo's `hk.pkl` clears
  `check_diff`/`check_after_diff`/`check_list_files` on the ryl step and puts `--strict` on both `check` and `fix` (the
  fix run is self-verifying: exit 0 only when nothing remains to fix or flag); the overrides can be dropped once this
  lands.

- Upstream: file an issue against [owenlamont/ryl](https://github.com/owenlamont/ryl) asking for a way to silence the
  summary that `ryl format --check`/`--diff` unconditionally end with on stderr (`N files already formatted`; the
  formatter docs record it as designed). Probed 2026-11-14 on 0.29.0: no CLI flag silences it (`--check` has no
  `--quiet`; `--output-format` styles findings but the summary ignores the format selection) and `[output]` can route a
  whole format's rendering elsewhere but not drop the summary. No existing issue found searching `quiet`/`summary` the
  same day. The tombi/ruff hk builtins pass `--quiet` and are silent; this repo's workaround (hk `ryl-format` step): the
  check routes its diff preview to stdout via `--config-data 'output = { standard = { path = "-" } }'` and drops stderr,
  keeping failures verbose. The routing and stderr drop can be replaced by the flag once it lands.

- Upstream: file an issue against [owenlamont/ryl](https://github.com/owenlamont/ryl) asking for a way to exclude
  lockfiles generically instead of pattern-by-pattern. ryl's file-skipping knobs (`exclude`, `exclude-from-file`,
  per-rule `ignore`) are all hand-written glob lists: no default ignore list and no lockfile awareness anywhere in the
  source (code search over `owenlamont/ryl`, 2026-11-16: only its own release tooling mentions lockfiles), and its
  docs/README demonstrate naming `pnpm-lock.yaml` by hand. The motivating example is vendir's `vendir.lock.yml` (this
  repo's vendored-skills lockfile, root `KNOWLEDGE.md` §"Vendored agent skills"): machine-regenerated on every
  `vendir sync`, never hand-edited, and emitted in a style ryl's formatter does not match, so it must be excluded from
  lint and format alike – listed in `.ryl.toml`'s `exclude` and mirrored in `hk.pkl`'s `ryl-format` step (the mirror
  exists because that step's check passes `--config-data`, which bypasses file-config discovery). Closest available
  today is a basename glob (`*.lock.yml` matches at any depth, gitignore-style) – still hand-written and over-broad,
  since it would also silence human-authored `*.lock.yml` content. Desired: something generic – built-in exclusions for
  known YAML lockfiles (`pnpm-lock.yaml`, `vendir.lock.yml`, …) or a lockfile toggle. No existing issue found searching
  `lockfile`/`exclude lock` the same day. The explicit patterns can shrink once it lands.

- Upstream: file an hk PR against [jdx/hk](https://github.com/jdx/hk) adding a `panache` builtin
  (`pkl/builtins/panache.pkl`): [panache](https://github.com/jolars/panache) is the Markdown formatter this repo runs as
  a custom hk step (`check = panache format --check {{files}}`, `fix = panache format {{files}}` over
  `**/*.md`/`**/*.markdown`), installed via the aqua registry (`aqua:jolars/panache`), so a builtin would let repos drop
  the custom step the same way the rumdl/ryl builtins do. Design point to settle in the PR: hk passes explicit file
  paths, and panache bypasses its own config excludes for explicit paths (observed here – hence the `mdExcludes` for
  `AI_POLICY.md` and `**/LICENSE.md` in `hk.pkl`); decide whether the builtin filters such files itself, documents the
  interaction, or waits for panache to honor excludes on explicit paths.

- Upstream: file an hk PR against [jdx/hk](https://github.com/jdx/hk) adding a `dockerfmt` builtin
  (`pkl/builtins/dockerfmt.pkl`): [dockerfmt](https://github.com/reteps/dockerfmt) is the Dockerfile formatter this repo
  runs as a custom hk step (`check = dockerfmt -d {{files}}`, `fix = dockerfmt -w {{files}}` over `**/Dockerfile`), so a
  builtin would let repos drop the custom step the same way the shfmt/rumdl/ryl builtins do. No hk issue or PR mentions
  dockerfmt yet (searched 2026-11-15).

- Upstream: investigate whether [shellharden](https://github.com/anordal/shellharden) mangles `for` loops and file an
  issue if none exists (check for existing ones first). Verified with v4.3.2 (2026-10): `--transform`/`--replace` quotes
  command substitutions in the iterable – `for _ in $(seq 1 120)` becomes `for _ in "$(seq 1 120)"` – which kills word
  splitting and makes the loop run exactly once (shellcheck flags the result as SC2066, error severity); an unquoted
  substitution in a for iterable is the idiomatic splitting form and not flagged by shellcheck. Minimal repro is a
  4-line script; the workaround rule (brace expansion, `read -r -a`, `mapfile`) and the 9 repo sites rewritten
  accordingly are documented in skill `ha-app-tooling`. The same run also confirmed the cosmetic nit of `[ -n "$x" ]`
  being rewritten to `[ "$x" != "" ]`. A second, worse defect (same version): the parser loses sync on nested
  parentheses inside arithmetic expansion – `printf '%04x' "$(( (a << 8) | b ))"` reports "the parser got lost" on a
  syntactically complete file, and everything after it is mangled (spurious `""` prefixes; quotes inserted into
  single-quoted strings, which corrupts generated output). Flat arithmetic (`$(( 10#$a ))`) is unaffected – but an
  arithmetic `<<` alone also breaks it (verified 2026-11, v4.3.2: `$((5 << attempt))` → "Unexpected end of file" on a
  syntactically complete file, likely lexed as a heredoc delimiter; `$((5 * 2 ** attempt))` parses and is equivalent).
  The one repo site was rewritten arithmetic-free (`printf '%02x%02x'`; workaround rule in skill `ha-app-tooling`). If
  upstream is unresponsive, reconsider whether shellharden should stay a fix step here (vs check-only or dropped).

- deploy:local pre-flight: give `.mise/tasks/deploy/local.sh` a pre-install probe of the build containers' DNS path (the
  Supervisor's on-device `docker buildx` RUN steps run on the default bridge, whose `resolv.conf` is a verbatim copy of
  the host's) that fails early with an actionable message instead of the Supervisor's cryptic "An unknown error occurred
  while trying to build the image" – device-verified 2026-11-12 (apk warned "DNS: transient error (try again later)" on
  both APKINDEX fetches, then failed with the misleading "no such package" for both pins). Mechanism: root
  `KNOWLEDGE.md` §"Supervisor: DNS resolution chain (CoreDNS)"; repro: ephemeral
  `docker run --rm ghcr.io/home-assistant/base:3.24 apk update` on the device. App-side counterpart:
  `hickory-dns/TODO.md`.

- entire-agent-goose pin bumps: automate the manual commit-pseudo-version bumps the mise.toml pin comment defers to
  hand-editing plus `mise lock` – Renovate can't own them. Its mise manager resolves `go:`-backend deps against the Go
  module proxy by package path (verified 2026-11-14 in Renovate's `lib/modules/manager/mise/`: `extract.ts` case `go` →
  `createGoToolConfig` → `GoDatasource`), and the proxy has no versions for
  `…/agents/entire-agent-goose/cmd/entire-agent-goose` (main-package path inside a module whose `external-agents`
  upstream carries no tags/releases), so lookups return nothing and the pin drifts silently. Desired: drift detection
  plus a bump path. Most in this repo's grain: a `bump-entire-agent-goose` mise task (latest commit touching
  `agents/entire-agent-goose` via the GitHub API → pseudo-version from the UTC commit time plus 12-char SHA → rewrite
  the pin, `mise lock`; mirroring `bump-hk`) plus a drift validate task on the daily cron like `validate:apk-pins`
  (main-pushes-and-cron-only: the upstream publishing state is not the PR's). A Renovate custom datasource fronting the
  upstream path's commit list would instead fold the dep into the weekly Monday cadence – viable if the endpoint tax is
  acceptable. If upstream ever tags the module, switch the pin to the real semver (Renovate's go datasource takes over)
  and drop this item.

- Upstream: file an issue (and potentially a PR) against
  [entireio/external-agents](https://github.com/entireio/external-agents) for goose subagent checkpoint support (adapter
  `agents/entire-agent-goose`). Goose natively emits `SubagentStart`/`SubagentStop` and keeps subagent sessions as
  separate `sessions.db` rows (`session_type='subagent'`) – capture-verified in the adapter's own research (its
  AGENT.md, against goose 1.37.0; goose's published hooks page does not list the two events, so re-verify against the
  goose version in use) – but the adapter declares `subagent_aware_extractor: false` ("defer") and the installed project
  plugin (`.agents/plugins/entire/hooks/hooks.json`) registers only the four session/turn events, so goose subagent work
  yields no task records and no subagent transcript: subagent edits surface only implicitly, via git state at the next
  main-session checkpoint. The external-agent protocol already carries `SubagentStart`/`SubagentEnd` (`tool_use_id`,
  `subagent_id`, `subagent_type`, `task_description` – `entireio/cli` `docs/architecture/external-agent-protocol.md`)
  and the CLI parses them for every built-in agent (Claude Code, Codex, Cursor, OpenCode, Copilot CLI, Factory), so the
  ask is scoped: register the two Subagent hooks in the goose plugin and implement subagent-aware extraction, in-session
  task records first (entire's changelog, PR #1958, records even Codex's subagent support as in-session-only). Their
  `docs/architecture/agent-integration-checklist.md` (plus `.claude/skills/agent-integration/researcher.md`) define the
  bar an adapter PR must meet. Drop once the goose plugin declares the hooks and subagent work appears in checkpoints.

- Upstream: file an issue against [entireio/entire-brain](https://github.com/entireio/entire-brain) (and likely a second
  one against [entireio/cli](https://github.com/entireio/cli)) – together they pin `entire brain distill --agent codex`
  to the built-in OpenAI provider for anyone whose codex uses a custom `model_provider`. The brain hardcodes
  `--ignore-user-config` into both of its `codex exec` argv builders (distill:
  `internal/cli/internal/base/agent_args.go`, seed: `internal/cli/seed.go`; code-read 2026-11-24 at `efa192e10186`), so
  the worker never loads the user-level `config.toml` (`model_provider`/`model_providers`, model and effort defaults)
  and silently falls back to the built-in OpenAI provider (401 without OpenAI auth) – deliberate isolation of workers
  from personal config, with the provider half as a side effect. Compounding it, the CLI filters the plugin child
  environment to an allowlist whose design intent is that credential-like names require an explicit opt-in
  (`cmd/entire/cli/plugin_env.go`; code-read 2026-11-24 at `c5f58fc0a945`, behavior live on the `entireio-cli` 0.13.4
  mise pin): `CODEX_HOME`, `CODEX_SQLITE_HOME`, `OPENROUTER_API_KEY` and any other provider `env_key` never reach the
  worker, so a custom provider could not resolve even with the flag gone. Desired: (a) drop the flag or make the
  worker-config isolation opt-out, and (b) default-allow-list `CODEX_HOME`/`CODEX_SQLITE_HOME` (config and state
  locations, not credentials) and pass through provider `env_key`s – codex reads auth from `$CODEX_HOME` even under the
  flag, so the location vars are the safe half; per-project opt-backs cannot fix the watch daemon anyway, since
  `internal/cli/setup.go` `daemonEnv` gives its unit only the plugin dirs and `PATH`. Worked around until then: a
  repo-local PATH shim (`.mise/shims/codex`, first on PATH via `mise.toml` `[env]` `_.path`) stripping the flag from
  `codex exec` invocations plus `ENTIRE_PLUGIN_ENV = "CODEX_HOME,CODEX_SQLITE_HOME,OPENROUTER_API_KEY"` in `mise.toml`
  `[env]`. Drop this item – and the shim with it – once both upstream changes land.

- CLAUDE.md shim: remove the repo-root `CLAUDE.md → AGENTS.md` symlink at the end of 2026 – the grace period for Claude
  Code users to update their harness. Decisive fact: Claude Code v2.1.277 (2026-09-18) reads `AGENTS.md` as its project
  instructions natively whenever no `CLAUDE.md`, `.claude/CLAUDE.md` or `CLAUDE.local.md` exists in the working
  directory or above it, so the shim only still serves such sessions; goose, Codex, Cursor and friends read `AGENTS.md`
  natively regardless. Nothing in the repository references `CLAUDE.md` (verified 2026-11-14). If such legacy sessions
  ever matter again, a one-line `@AGENTS.md` `CLAUDE.md` import is the Windows-safe replacement.
