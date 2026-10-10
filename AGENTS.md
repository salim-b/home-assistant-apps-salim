# AGENTS.md

Instructions for coding agents working on this repository. Human-relevant
information lives elsewhere — see the placement rule below.

## What this repository is

A [Home Assistant app repository](https://developers.home-assistant.io/docs/apps/)
(formerly "add-ons"): each app is a subdirectory with a `config.yaml`,
`Dockerfile`, `rootfs/`, docs, translations, and its own `TODO.md` /
`KNOWLEDGE.md`. Currently contains `nfs-server` (an NFSv4 server app running
the NFS server in the host kernel via the HAOS kernel module — the
architecture and its gotchas are non-obvious: read
`nfs-server/KNOWLEDGE.md` before touching the app's runtime code).

## Information placement rule

Never duplicate information across files. Place it where it belongs and
reference it from everywhere else:

- `README.md` — human users: what the repo is, how to install/test on a device.
- `<app>/DOCS.md` — end-user documentation (shown in the HA UI): usage,
  configuration, requirements. Must not duplicate the option field
  descriptions from `translations/en.yaml` — point at the UI instead.
- `<app>/CHANGELOG.md` — user-visible changes per version.
- `<app>/KNOWLEDGE.md` — cross-session technical facts: root causes, kernel/
  container design facts, gotchas (e.g. the writev/EINVAL issue). Write a
  new entry whenever you learn something non-obvious that outlives the
  current change.
- `<app>/TODO.md` — open work items and plans.
- `AGENTS.md` (this file) — agent-specific process and commands only.

## Environment setup

```sh
mise trust               # first use: mise config files are untrusted until then
mise install --locked    # pinned tools from mise.toml/mise.lock
```

`docker` is required for the `build`, `lab`, `deploy` and `test:live` tasks
(image builds and the NFS client container). For interactive
supervisor-integrated testing use the devcontainer (`.devcontainer.json`),
not the lab.

## Commands

Run `mise tasks ls --local` for the task list (the `--local` flag excludes
global tasks from your mise user config); the essentials:

- `mise run check` — lint + validate; **always run before finishing a change**.
- `mise run build` — build app images (native arch + cross-check) and assert
  image metadata.
- `mise run lab` — full-fidelity boot lab: fake Supervisor API serving the
  app's default options (adapted to the lab network), boots the app container
  (complete s6-rc tree), then an app-provided runtime check, then graceful
  stop. **Run for every runtime-affecting change**; it caught the
  mountd/pseudo-root class of bugs. `mise run lab --keep` keeps
  containers/dirs for debugging.
  - Apps without a `.mise/tasks/lab/<app>.sh` hook get a *boot-only* lab
    (config fetch, full boot, graceful stop, exit code 0) — zero ceremony
    for new apps.
  - Hook contract (`.mise/tasks/lab/<app>.sh`, sourced by the harness; env:
    `LAB_NET_NAME`, `LAB_TMPDIR`, `LAB_APP_IP`, `LAB_SUBNET`): append to
    `lab_docker_args` (`lab_docker_args+=(…)` — do **not** overwrite it, the
    harness pre-seeds the `/data` volume), optionally set `lab_fixture_py`
    (app-relative python file defining `lab_adapt_fixture(options)`, with
    `LABNETWORK` as subnet placeholder), and define `lab_runtime_check`.
    See `.mise/tasks/lab/nfs-server.sh` as the reference.
- `mise run deploy <app> <host>` — deploy an app to a real device for testing:
  copies it to the device's `/local_apps` (removing the old copy), reloads the
  store, then installs/updates/rebuilds depending on installed vs. local
  version, and ensures it runs. Comments out the top-level `image:` key in the
  *device copy* so the Supervisor builds locally instead of pulling from GHCR.
  Refuses when the app is already installed from an app repository (hashed
  store slug, e.g. `f8b2d53d_nfs` — port conflict); `--replace` uninstalls
  that copy first.
- `mise run test:live <app> <host>` — deploy (forwarding `--replace`) plus
  live checks: per-share NFS client roundtrips from this machine (rw
  roundtrip / ro assertion / pseudo-root browse). `--test-options` applies
  the app's test options (`.mise/tasks/test/live/<app>.yaml`, top-level key
  override) to the device app for the run — options are user data and are
  NOT refreshed from config.yaml defaults on update/rebuild — with an
  options backup restored on exit. App-specific checks live in the per-app
  hook `.mise/tasks/test/live/<app>.sh` (contract: `live_prepare`,
  `live_runtime_check`, `LIVE_*` vars — analogous to the lab hooks); apps
  without a hook get deploy + state-wait only. Restriction: native mise
  depends-arg forwarding is not implemented in any released mise (docs
  describe it; verified up to 2026.10.6) — the task forwards via its run
  script instead.

## Workflow rules

- **Branch discipline**: work on a branch named `agent-<topic>`; *always
  check the current branch first* (`git status`) — the checkout often sits
  on `main` after merges, and commits have repeatedly landed there by
  accident. If the work belongs on a branch and a stray commit already
  landed on `main`: move it (`git switch -c agent-…; git branch -f main
  <upstream-tip>`) and disclose it to the user. Never stage unrelated WIP:
  check `git status` before staging and add files explicitly.
- **Commits**: Conventional Commits (`fix:`/`feat:`/`docs:`/`chore:`/…);
  scope app changes (`fix(nfs-server): …`); one commit per logical unit;
  final trailer line `Assisted-by: Goose:<model-slug>`.
- **App releases**: a working branch starting from `main` bumps
  `version` in `config.yaml` to a *single* next version (major, minor or
  patch according to semantic versioning — the branch ships one version,
  not one per commit) and continuously expands that version's
  `CHANGELOG.md` entry until the branch lands on `main`. Transitory extra
  versions within the branch are fine where testing demands a version bump
  (AppArmor profile changes are only re-applied on app *update*, never on
  rebuild) — squash them back into the single version (config + one merged
  changelog entry) before merging.
- **CI/CD is the source of truth for what gets published**: pushes to `main`
  build and publish images (see `.github/workflows/builder.yaml`). If CI
  fails, fix the repo, not CI config, unless the CI config itself is wrong.
  Builder caveats: the init job needs `fetch-depth: 0` — the changed-files
  filter otherwise only sees the tip commit and silently skips multi-commit
  merges (regular merges instead of squash!). The app Dockerfile must
  not pull from Docker Hub at build time (this includes the
  `# syntax=docker/dockerfile:1` directive — its frontend image comes from
  Docker Hub; buildx's builtin frontend suffices). The lint workflow runs
  frenck's app linter natively (pinned source + pypi requirements) instead
  of via its Docker action, whose Docker Hub image builds flaked with 504s
  and 429 runner-pool rate limits.
- **Device access**: testing against the real HA device over SSH only on
  explicit user request; otherwise hand the user exact commands to run.
- **Version-sensitive facts**: supervisor schemas, s6-overlay layout, HAOS
  kernel configs, HA docs change frequently. Wherever such facts are written
  down (KNOWLEDGE.md, comments), cite source (URL + version/ref). Before
  *relying* on them for new work, re-verify against the latest docs/source.
- **Design change proposals**: when a fix reveals a design issue (like the
  mountd requirement did), diagnose hands-on first (strace, packet captures,
  a reproduction lab), then explain root cause, options and trade-offs to
  the user before rewriting.

## Tool notes

- mise tasks: file tasks in `.mise/tasks/` with proper suffixes (`.sh`,
  `.py`, … — mise resolves the short names, e.g. `mise run lint`) and
  `#MISE`/`#USAGE` headers. Task arguments must be documented and typed via
  usage specs (never bare `$1` handling unless `raw_args = true`).
  Required args are declared `arg "<name>"` (mise errors before the task
  starts when missing — no manual checks); read them with `${usage_name?}`,
  optional ones with `${usage_name:-…}` defaults, boolean flags with
  `${usage_name:-false}` (mise docs, "Read argument values"); in Python
  tasks the values are exported as `usage_<underscored_name>` env vars.
- `.mise/tasks/validate.py` fetches supervisor schemas from the ref pinned in
  `mise.toml` `[vars].supervisor_ref` (cached under `~/.cache/`). Renovate
  bumps the pin to the newest supervisor release and **automerges the bump
  once the CI `check` job is green** — green means the new schemas validate
  our app configs (rebase-merge strategy, see `.github/renovate.json`).
  Renovate does not track schema-*behavior* changes:
  re-verify version-sensitive supervisor facts against the new ref when
  relying on them (see the version-sensitive-facts rule above). validate.py
  also schema-validates `.github/renovate.json` against the published
  Renovate config schema (refetched whenever that file changes).
- The HA base image's bash emits `echo`/`printf` as `writev(2)` — it cannot
  write to procfs transaction files (`/proc/fs/nfsd/*`); see
  `nfs-server/KNOWLEDGE.md` before writing to any such file from app code.
