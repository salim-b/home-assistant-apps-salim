---
name: ha-app-workflow
description: Change and release discipline for this Home Assistant apps repository — branching, Conventional Commits,
  lint gates, the single-version-per-branch release rule with changelogs, CI-as-source-of-truth, device-access policy,
  and the version-sensitive-facts rule. Use before making any change, commit, or release in this repo.
---

# Change and release workflow

## Before starting

- Check the current branch first (`git status`): the checkout often sits on `main` after merges, and commits have
  repeatedly landed there by accident. Work on a branch named `agent-<topic>`.
- If work belongs on a branch but a stray commit already landed on `main`: move it
  (`git switch -c agent-…; git branch -f main <upstream-tip>`) and disclose it to the user.
- Never stage unrelated WIP: check `git status` before staging and add files explicitly.

## Commits

- Conventional Commits (`fix:`, `feat:`, `docs:`, `chore:`, …); scope app changes (`fix(nfs-server): …`); one commit per
  logical unit.
- Final trailer line: `Assisted-by: Goose:<model-slug>` — the model name without provider prefix, e.g.
  `Assisted-by: Goose:glm-5.3-flash`.
- The commit-msg hook enforces the format; escape hatch `HK=0 git commit`.

## Before finishing a change

Run `mise run check` — lint plus validate; it is the same gate CI runs. Lint-stack details and scoped checking: skill
`ha-app-tooling`. Task usage: `mise run check --help`.

## App releases

- A working branch starting from `main` bumps `version` in `config.yaml` to a **single** next version (major, minor or
  patch by semantic versioning): the branch ships one version, not one per commit, and continuously expands that
  version's `CHANGELOG.md` entry until it lands on `main`.
- Transitory extra versions within the branch are fine where testing demands one (AppArmor profile changes are only
  re-applied on app *update*, never on rebuild) — squash them back into the single version (config plus one merged
  changelog entry) before merging.
- CI enforces the rule: `.github/workflows/version-guard.yaml` fails when device-visible app files (rootfs, Dockerfile,
  config.yaml, apparmor.txt, translations) changed without a version bump — the Supervisor's update model makes a
  no-bump change a silent no-op that only repoints an already-published version tag. Docs-only files (README, DOCS,
  CHANGELOG, KNOWLEDGE, TODO, `.agents/`, repo tooling) do not require a bump.

## CI/CD is the source of truth for what gets published

- Pushes to `main` build and publish images (`.github/workflows/builder.yaml`). If CI fails, fix the repo, not CI config
  — unless the CI config itself is wrong.
- Builder caveats: the init job needs `fetch-depth: 0` — the changed-files filter otherwise only sees the tip commit and
  silently skips multi-commit merges, so use regular merges instead of squash merges.
- The app Dockerfile must not pull from Docker Hub at build time — this includes the `# syntax=docker/dockerfile:1`
  directive (its frontend image comes from Docker Hub; buildx's builtin frontend suffices).
- The lint workflow runs frenck's app linter natively (pinned source plus pypi requirements), not via its Docker action
  (whose Docker Hub image builds flaked with 504s and 429 runner-pool rate limits).

## Device access

Testing against the real HA device over SSH only on explicit user request; otherwise hand the user exact commands to
run. On-device procedures: skill `ha-app-device-testing`.

## Version-sensitive facts

Supervisor schemas, s6-overlay layout, HAOS kernel configs and HA docs change frequently. Wherever such facts are
written down (KNOWLEDGE.md, comments, skills), cite the source (URL plus version/ref). Before relying on them for new
work, re-verify against the latest docs/source.

## Design change proposals

When a fix reveals a design issue, diagnose hands-on first (strace, packet captures, a reproduction lab), then explain
root cause, options and trade-offs to the user before rewriting.

## Text files

Every text file ends with a final newline (the lint gate enforces it).
