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
- `<app>/TODO.md` and `TODO.md` — open work items and plans.
- `AGENTS.md` (this file) — agent-specific process and commands only.

## Environment setup

```sh
mise install --locked    # pinned tools from mise.toml/mise.lock
```

`docker` is required for the `build` and `lab` tasks. For interactive
supervisor-integrated testing use the devcontainer (`.devcontainer.json`),
not the lab.

## Commands

Run `mise tasks ls` for the task list; the essentials:

- `mise run check` — lint + validate; **always run before finishing a change**.
- `mise run build` — build app images (native arch + cross-check) and assert
  image metadata.
- `mise run lab` — full-fidelity boot lab: fake Supervisor API serving the
  app's default options (adapted to the lab network), boots the app container
  (complete s6-rc tree), client-mount roundtrip (rw write must reach the host
  filesystem, ro must be blocked), graceful stop. **Run for every
  runtime-affecting change**; it caught the mountd/pseudo-root class of bugs.
  `mise run lab --keep` keeps containers/dirs for debugging.

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
- **App releases**: bump `version` in `config.yaml` + add a CHANGELOG entry
  for every functional change; user-visible behavior changes belong in the
  changelog.
- **CI/CD is the source of truth for what gets published**: pushes to `main`
  build and publish images (see `.github/workflows/builder.yaml`). If CI
  fails, fix the repo, not CI config, unless the CI config itself is wrong.
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

- mise tasks: file tasks in `mise-tasks/` with proper suffixes (`.sh`,
  `.py`, … — mise resolves the short names, e.g. `mise run lint`) and
  `#MISE`/`#USAGE` headers. Task arguments must be documented and typed via
  usage specs (never bare `$1` handling unless `raw_args = true`).
- `mise-tasks/validate.py` fetches supervisor schemas from the ref pinned in
  `mise.toml` `[vars].supervisor_ref` (cached under `~/.cache/`). Bump the
  pin deliberately; review schema-related failures against the ref.
- The HA base image's bash emits `echo`/`printf` as `writev(2)` — it cannot
  write to procfs transaction files (`/proc/fs/nfsd/*`); see
  `nfs-server/KNOWLEDGE.md` before writing to any such file from app code.
