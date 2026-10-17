# TODOs

Cross-app work items (tooling, CI, harnesses); app-specific items live in each app's `TODO.md`. Underlying technical
facts live in the repository-root `KNOWLEDGE.md`.

## Tasks

- Automate Alpine apk-pin app releases end-to-end (design decided 2026-10-17; written up self-contained below.
  Background: the apk package version policy in the repository-root `KNOWLEDGE.md` - Alpine repoints a pinned package
  (e.g. `hd-idle=1.22-r7` -> `1.22-r8`, released as app 0.1.7 via PR #3), `validate_apk_pins` in
  `.mise/tasks/validate.py` fails loudly (the drift alarm), and the release is then finished by hand: the Renovate bump
  PR (experimental `bumpVersions` bumps the app's `config.yaml` version) still needs a hand-written changelog entry and
  a manual merge. The Mend Renovate GitHub App was installed 2026-10-17 (UI-only step; the onboarding PR is skipped
  because `.github/renovate.json` already exists on `main`; free plan: ~4 h run cadence, automerge not plan-gated).
  Goal: Renovate automerges pkgrel bumps once CI is green, a CI job fills the changelog after the merge, and a daily
  reconcile job self-heals missed image publishes.

  Verified platform facts the design relies on (do not re-research; if anything contradicts current docs, stop and
  report instead of guessing):

  - The hosted Renovate app merges automerge PRs with its own app installation token (`renovate[bot]`), so its merge
    push **does** fire `on: push` workflows - the workflow suppression applies only to the repository's `GITHUB_TOKEN`.
    The only `GITHUB_TOKEN` push in this design is the docs-only changelog commit, where suppression is wanted
    (CHANGELOG.md is excluded by version-guard and the image is byte-identical, so no rebuild is needed).
  - The repo has no branch protection and "Allow auto-merge" is off, so Renovate's default `platformAutomerge: true`
    falls back to Renovate's own merge, which waits for passing checks. Belt-and-braces: set `platformAutomerge: false`
    at top level so enabling the repo toggle later cannot cause merges before CI finishes.
  - The apk datasource's `apk` versioning classifies pkgrel-only bumps (`1.22-r7` -> `1.22-r8`) as updateType `patch`
    and pkgver bumps as `minor`/`major`: automerge only `patch` (an Alpine rebuild of the same upstream release, CLI
    unchanged by definition), keep human review for `minor`/`major` (per the apk policy, CLI semantics may change, cf.
    `hd-idle-genargs`).
  - `workflow_dispatch` is the documented `GITHUB_TOKEN` exception that always creates runs: `build-app.yaml` gains that
    trigger, and a daily reconcile job dispatches it when a published version tag is missing from GHCR (self-healing;
    idempotent - the push-fired Builder still publishes on merge, reconcile only fires on a genuine miss such as a
    transient build failure).
  - GHCR naming (verified against the live registry 2026-10-17): per-arch `ghcr.io/salim-b/{amd64,aarch64}-app-<name>`
    plus the multi-arch manifest under `ghcr.io/salim-b/app-<name>` (prefix/name split of the `image:` value); anonymous
    pull-token checks work (`GET https://ghcr.io/token?scope=repository:salim-b/<repo>:pull`, then
    `GET /v2/salim-b/<repo>/manifests/<tag>` with the OCI Accept header list).
  - Alpine repushes land per-arch asynchronously (aarch64 served 1.22-r8 days before x86_64, see KNOWLEDGE.md): an early
    bump PR stays red until the lagging arch's index catches up. A daily nudge job rebases such PRs (`@renovate rebase`)
    once all arch indexes serve the new pin; do not re-run failed check runs instead (re-runs can still count as red in
    Renovate's automerge evaluation; a rebase creates fresh checks).

  Subtasks (suggested PR split: the version-guard fix first as its own PR - `main` is currently red on it - then the
  automation as one PR; branch prefix `agent-`, conventional commits, follow `AGENTS.md`):

  - version-guard: stop failing on comment-only changes. Run 39057776214 ("Version guard") fails on `abfb7c5` ("docs:
    update official HA docs links"), which changed only comment lines (both apps' `Dockerfile`/`config.yaml` header
    comments, plus the nfs-server `apparmor.txt` `##` block). The guard's per-file trigger counts comment-only hunks.
    Fix: ignore hunks whose changed lines are comments/blank only (`#`-prefixed) in the device-visible files; any
    non-comment change must still trigger. Verify: reproduce the `abfb7c5` failure locally pre-fix and green post-fix,
    plus a synthetic content-change commit pair that must still fail. `mise run check` before finishing.
  - `.github/renovate.json`: split the apk rule by update type. Restructure the single apk packageRule into chained
    rules: a base rule (`matchDatasources: ["apk"]`) keeping the `bumpVersions` entry (rename it - it is generic, not
    hd-idle-only), the `registryUrls` (Alpine v3.24, x86_64 + aarch64) and the `apk_pin` label; a rule with
    `matchUpdateTypes: ["patch"]` setting `automerge: true` + `automergeStrategy: "rebase"` (same rationale as the
    supervisor-pin rule: linear history, conflicts block the automerge); a rule with
    `matchUpdateTypes: ["minor", "major"]` adding the `needs-review` label (automerge stays off). Add top-level
    `"platformAutomerge": false`. Update the rule descriptions - the current text ("No automerge: the changelog entry is
    still missing") is obsolete once the CI changelog job exists. `mise run check` schema-validates the file
    (`validate_renovate_config`).
  - `.github/workflows/build-app.yaml`: add a `workflow_dispatch` trigger next to `workflow_call` with the same inputs
    (`app` string, `publish` boolean; the prepare job's `github.repository` guard already applies). Smoke-test on the
    branch: `gh workflow run build-app.yaml --ref <branch> -f app=hd-idle -f publish=false` (builds without pushing; the
    run must be findable via `gh run list -w build-app.yaml -c <sha>`).
  - New `.github/workflows/publish-reconcile.yaml` - daily GHCR reconciliation, generic for all apps (not apk-specific):
    daily cron (UTC; pick an offset away from lint's 00:00 and the apk nudge below), explicit
    `permissions: contents: read, actions: write`, a concurrency group, and job logic: find apps via
    `home-assistant/actions/helpers/find-addons@master`, read version/image/arch from `config.yaml` via
    `home-assistant/actions/helpers/info@master`, then check the per-arch tag `<prefix>/<arch>-<image_name>:<version>`
    for every arch in config plus the multi-arch `<image_name>:<version>` tag. Missing anything -> dispatch
    `build-app.yaml` (`app=<app>`, `publish=true`, `ref=main`). Outcomes: everything published -> green + step summary
    table; tag missing -> dispatch + green with a summary note (the dispatched Builder run is the loud signal if
    publishing keeps failing); GHCR unreachable or dispatch failed -> red. Keep it idempotent (only dispatch on a real
    miss) and document the known limitation in a workflow comment (tag existence only; stale-content tags are not
    detected - content drift is version-guard's/validate's domain). Test: local dry-run against the current registry
    state (all hd-idle 0.1.7 tags exist as of 2026-10-17 -> zero dispatches).
  - New `.github/workflows/apk-bump.yaml` - post-merge changelog + skew-window nudge, two jobs:
    - changelog job: `pull_request: closed` with `merged == true`, base `main`, author `renovate[bot]`, label `apk_pin`
      (covers Renovate automerges and manually merged pkgver PRs alike - the PR author is `renovate[bot]` in both
      cases); permissions `contents: write` + `pull-requests: read`. Fetch the PR's files via REST
      (`GET /repos/{owner}/{repo}/pulls/{n}/files` - robust across merge strategies) and parse each Dockerfile patch for
      apk pins (app dir, package, old pin, new pin) plus the config.yaml version bump (`bumpVersions` bumps it in the
      same PR). Check out `main`, run the mise task (below) to insert the templated `## <version>` section into each
      touched app's CHANGELOG.md - only when that heading is absent (idempotent: pre-written entries are never
      overwritten; no pins found -> green no-op), then `mise run fmt` + `mise run lint`, fetch --rebase onto origin/main
      (merge races with Renovate's own merges are possible), commit
      `docs(<app>): changelog for apk pin bump <old> -> <new>` and push with the `GITHUB_TOKEN` (workflow suppression
      intended - docs-only, version-guard excludes CHANGELOG.md, image unchanged).

    - changelog task: the templating lives in a mise task (`.mise/tasks/apk-changelog.py`, follow validate.py's script
      style; args `--app --pkg --old --new --version`, flag `--dry-run`) so CI and local runs share one code path. Use
      this generic template (deliberately generic; pkgrel-bump reasons like toolchain rebuilds vary):

      ```markdown
      ## <version>

      - Internals: bumped the pinned <pkg> package from <old> to <new> (Alpine package update; see the
        repository-root `KNOWLEDGE.md` apk package version policy).
      ```

    - nudge job: daily cron (UTC, offset), no checkout needed (REST + HTTP only): for every **open** `apk_pin` PR
      authored by `renovate[bot]`, read the new pin from the PR's Dockerfile files, check the Alpine binary indexes for
      the app's arches (branch from the PR Dockerfile's `BUILD_FROM` arg; repos `community` + `main`; same parse logic
      as validate.py's `_apkindex_versions`), and when ALL arch indexes serve the new pin, post a `@renovate rebase` PR
      comment (cap: 3 per PR - count prior `github-actions[bot]` comments to avoid loops). While an arch index still
      lags, do nothing: the PR legitimately stays red and the daily `main` cron remains the drift alarm. Permissions:
      `issues: write` (PR comments are issue comments) + `pull-requests: read`.
  - Docs & hygiene: extend the apk package version policy section in the repository-root `KNOWLEDGE.md` with the
    automation (patch/pkgrel automerge, minor/major review, CI changelog post-merge, daily nudge, publish-reconcile
    self-healing, `build-app.yaml` workflow_dispatch); close these TODO items as they land.

  Acceptance criteria: `mise run check` green; yamllint + actionlint (both pinned in mise.toml) clean on all new/changed
  workflows; `apk-changelog --dry-run` reproduces a PR #3-shaped entry; the publish-reconcile local dry-run reports
  everything current. The first real Alpine repoint after landing validates the flow end to end (drift cron red ->
  Renovate PR with the Automerge: Enabled badge -> green CI -> Renovate merge -> Builder publish -> changelog commit) -
  do not fake events; publish-reconcile can be exercised manually via workflow_dispatch.

- Upstream: file a formatter bug against [panache](https://github.com/jolars/panache) — its reflow is non-idempotent on
  a multi-line ~~strikethrough~~ inside a list item: the continuation line's indent grows by 2 spaces on every
  `panache format` run, so `format --check` never settles afterward — violating the formatter's documented idempotency
  golden rule ([formatting guide](https://panache.bz/guide/formatting.html)).

  Reproducer (panache 3.16.0, verified 2026-10; default settings suffice, the wrap just lands elsewhere at other
  line-widths):

  ```markdown
  - ~~Create upstream PR in HA to render app configuration labels in the UI as Markdown blocks instead of the current
    single-line plain text.~~
  ```

  Findings to include in the issue: every run re-indents the continuation +2 (4 → 6 → 8 …); top-level multi-line
  strikethroughs are stable, as are bold/strong and code spans wrapping inside list items — only strikethrough in a list
  item is affected; `-o extensions.strikethrough=false` does not help (the CST still yields a `STRIKEOUT` node with
  `NEWLINE` + `LINE_PREFIX` inside). Until fixed, this repo keeps struck spans on a single line (see `AGENTS.md`, tool
  notes).

## Resolved

- Repo sweep + dev tooling review (2026-10-16) done: the CI "redundancy" check resolved as proper architecture
  (build-app.yaml is a reusable `workflow_call` workflow invoked by builder.yaml; fetch-depth and squash-merge caveats
  documented). The SSH-helper factoring had one consumer until deploy-registry arrived - the shared lib
  (.mise/tasks/lib/ssh-ha.sh) landed together with it, and lint.sh now runs shellcheck with `-x` (follows `source`
  lines; without it the sourced helper produced SC1091 failures). nfs-server staleness pass: s6 ordering already correct
  (`dependencies.d/base` on every service); its comment-slimming pass is planned in nfs-server/TODO.md. New task
  `deploy-registry` shipped (see its header for the spec; config migration is opt-in with schema-key filtering). The lab
  boot marker (`legacy-services successfully started`) remains valid under the new s6 ordering. Hygiene and cross-app
  conventions checked clean. Follow-up (2026-10-16): both deploy tasks now take `--config migrate|reset` (mise usage
  `choices`-typed). reset wipes the target install's options (the repo config.yaml defaults are POSTed, not `{}` - a
  fresh POST is schema-validated and rejected for required keys, device-verified), migrate is unchanged, and unset =
  discard is now the default on deploy-registry (the deliberate refusal is gone). Every option set that dies with an
  uninstall, a discard or a reset is backed up to a local file first (path printed). Shared HA-API helpers (options
  read/POST, schema keys incl. the array-form shape, filter, backup) live in `.mise/tasks/lib/ssh-ha.sh`.
