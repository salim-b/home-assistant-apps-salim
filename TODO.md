# Repository TODO

Dev tooling & agent workflow plan for the whole repository. App-specific work
lives in the apps' own files (`nfs-server/TODO.md` etc.). New top-level work
items go here.

## Where we stand

- App development diligence is currently hand-crafted per session (as done
  for `nfs-server`): `shellcheck`/`bash -n` over scripts, YAML parse checks,
  voluptuous validation of `config.yaml`/`translations/` against supervisor
  schemas (throwaway venv in `/tmp`), local image builds, a container "lab"
  with a fake Supervisor API for full-fidelity boots, and client-mount
  roundtrips. None of this is codified — every agent or contributor
  re-derives it, inconsistently.
- Existing automation: CI (lint via `frenck/action-addon-linter`, image
  build+publish via `builder`/`build-app`, Renovate), the HA devcontainer
  for supervisor-integrated testing, `.editorconfig`, `.vscode/tasks.json`.
- Dev machines have mise (2026.10.x, current docs at <https://mise.jdx.dev> —
  consult them before implementing; the tool evolves fast). The repository
  has no `mise.toml`/`AGENTS.md` yet.

## Goals

- One deterministic command per diligence need — runnable locally, in the
  devcontainer, in CI, and by any coding agent: lint, validate, build, lab.
- Long-lived knowledge in the right files, agent-specific process in
  `AGENTS.md`, human docs human-focused.

## Phase 1 — mise foundation (`mise.toml`, tools, env)

- Add `mise.toml` at the repo root (single project; no env-specific files
  yet):
  - `[tools]`: the diligence toolset, version-pinned. Candidates, decide by
    actual need when implementing (check the mise registry/backends for
    each): `shellcheck` (scripts), `actionlint` (GH workflows), `hadolint`
    (Dockerfile), `yamllint` (yaml style), `python` (validation harness),
    `uv` (run python deps ad hoc via `uv run --with …`, no venv churn), `jq`
    (also in HA base images, but useful on dev machines), `yq` (yaml-jq).
  - `[env]`: e.g. `DOCKER_BUILDKIT = "1"`; nothing secret, no redaction
    needed.
  - `[settings]`: keep minimal; only set `experimental = true` if phase 5
    (daemons) is adopted. Use `mise fmt` to keep the file canonical.
- Create `mise.lock` (`mise lock`, or `lockfile = true` so mise maintains
  it) and commit it; `mise install --locked` everywhere. Review `mise.lock`
  diffs like dependency PRs.
- Verify with `mise doctor` (and `mise tasks validate` once phase 2 exists).

## Phase 2 — tasks (TOML one-liners + file tasks)

TOML tasks in `mise.toml` for short commands; executable file tasks in
`mise-tasks/` (with `#MISE description="…"` headers) once a script needs
editor highlighting/linting; wire with `depends`; `sources`/`outputs` on
tasks whose inputs/outputs allow caching; bare `mise run` shows the picker.

Task inventory, mapped 1:1 from the hand-crafted diligence list:

- `lint`: shellcheck all `rootfs/` scripts (set `sources` to the globs →
  cached), `bash -n` per script, `actionlint` on `.github/workflows/`,
  `hadolint` on `nfs-server/Dockerfile`, `yamllint` on
  `config.yaml`/`translations/`/workflows/`repository.yaml`.
- `validate`: python harness via `uv run --with voluptuous --with pyyaml
  mise-tasks/validate.py`: YAML-parse + supervisor schema checks —
  translations against `SCHEMA_APP_TRANSLATIONS` (incl. `fields` nesting,
  lowercase `network` port keys), `config.yaml` against the app schema, and
  the apparmor profile-name regex from supervisor's `utils/apparmor.py`.
  Copy the schemas from a **pinned supervisor ref** (cite the ref in a
  comment); this complements the CI linter (which validates HA-side
  expectations) with supervisor-side semantics at a known version.
- `build`: `docker buildx build` each app for `linux/amd64` and
  `linux/arm64` (no build args needed since the `BUILD_FROM` fix); assert
  the OCI labels and `HEALTHCHECK` in the built image.
- `lab`: the full-fidelity boot lab as a file task — fake Supervisor API
  serving `/addons/self/options/config` from a fixture (bashio honors
  `SUPERVISOR_API`/`SUPERVISOR_TOKEN` env overrides) → boot the app
  container (complete s6-rc tree, config fetched over the API like on a
  real device) → client container mounts each share (rw roundtrip onto a
  host bind dir, ro enforcement) → graceful stop (down-script teardown).
  Run for every runtime-affecting change; it caught the
  mountd/pseudo-root class of bugs.
- `check` (default entry): `depends = ["lint", "validate"]` — "always run
  before finishing a change".
- Optional: `watch` (mise watch lint over script sources), `release` (assert
  `config.yaml` version == newest `CHANGELOG.md` entry, with `confirm`),
  `docs` (`mise generate task-docs` → committed task reference).
- Task arguments via usage specs only where they earn their keep.

## Phase 3 — `AGENTS.md` (+ pointer docs)

Create `AGENTS.md` per the [agents.md spec](https://agents.md/) — plain
markdown, a "README for agents", free-form sections. Content plan:

- Project context: HA app repository, per-app directories, currently
  `nfs-server`. Pointers: `README.md` (humans: usage, device testing),
  `nfs-server/DOCS.md` (end-user docs, shown in the HA UI),
  `nfs-server/CHANGELOG.md`, `nfs-server/TODO.md` (app plan incl. the
  security hardening plan), `nfs-server/KNOWLEDGE.md` (root causes and
  gotchas — read before touching the app), repo-wide `TODO.md` (this plan).
- **Information placement rule** (write it down explicitly): human-relevant
  information belongs in `README.md`/app docs, cross-session technical facts
  in `KNOWLEDGE.md`, open work in the `TODO.md` files, agent-only process in
  `AGENTS.md`. Never duplicate: `AGENTS.md` points, `KNOWLEDGE.md` explains,
  docs instruct.
- Environment: `mise install --locked` first; docker needed for
  `build`/`lab`; the devcontainer for supervisor-integrated testing.
- Commands: `mise run check` before finishing any change, `mise run lab` for
  runtime-affecting changes, `mise tasks ls` for the rest.
- Workflow rules (codify what's practiced): work on `agent-` branches — and
  verify the current branch first (the checkout often sits on `main` after
  merges; never commit to `main` directly); Conventional Commits with a
  final `Assisted-by: Goose:<model-slug>` trailer; one commit per logical
  unit; never stage unrelated WIP (check `git status` before staging); bump
  app version + CHANGELOG for every functional change; keep
  runtime-affecting changes lab-verified before claiming done.
- Device access: testing against the real HA device (SSH) only on explicit
  user request; otherwise hand exact commands to the user to run.
- Version-sensitive facts (supervisor schemas, s6-overlay layout, HAOS
  kernel config): wherever they are written down, cite the source (URL +
  version/ref); agents must re-verify against the latest docs before
  relying on them.

## Phase 4 — CI + devcontainer integration

- CI: add a job running the same mise tasks (single source of truth). When
  implementing, evaluate `mise generate github-action` (official generator)
  vs. the docs' manual setup; cache `~/.local/share/mise/installs` and the
  mise cache keyed on `mise.lock`. Keep `frenck/action-addon-linter` — our
  `validate` complements it with supervisor-side semantics.
- Renovate: check whether its mise manager covers `[tools]` version updates
  (Renovate has a mise manager) — enable, so tool bumps arrive as lockfile
  PRs to review.
- Devcontainer: ensure mise is available (feature or preinstalled in the HA
  devcontainer image — check) and runs `mise install --locked` on
  postCreate; keep `.vscode/tasks.json` (supervisor workflows) as-is.

## Phase 5 — daemons (optional, experimental)

- Only if desired: make the fake supervisor API a mise daemon
  (`[daemons.supervisor]`, `run = "…python3 …"`, `ready_port = 8000`) and
  `tasks.lab` with `daemons = "supervisor"`. Requires `[settings]
  experimental = true` and pitchfork ≥ 2.25 (auto-installed). The phase 2
  file-task fallback (background process inside the task) already works —
  don't adopt experimental daemons for this alone.

## Non-goals

- mise bootstrap/dotfiles (machine-level setup — out of repository scope).
- Replacing the HA devcontainer/supervisor workflows with pure-docker
  testing; both coexist (devcontainer = interactive supervisor testing,
  `lab` = scripted regression checks).

## Open questions

- Pin strategy for the supervisor schemas in `validate` (fixed ref vs. a
  regularly Renovate-bumped ref).
- Wire the mise MCP server (`mise mcp`: agents call `run_task` directly)
  into the devcontainer for goose agents — nice-to-have, evaluate after
  phases 1–3.
