---
name: ha-app-device-testing
description: How to verify Home Assistant apps on a real HAOS device — the deploy/deploy-registry/test:live tasks,
  stored-options fate and backups, and the per-app live-test hook contract. Use when the user asks for on-device testing
  or when lab verification is insufficient.
---

# Device testing

Tasks: `mise run deploy`, `mise run deploy-registry`, `mise run test:live`, `mise run hd-idle-drives`. Usage and flags
via `mise run <task> --help` — not duplicated here. Device access over SSH only on explicit user request (skill
`ha-app-workflow`); otherwise hand the user exact commands to run.

## Semantics that outlive the flags

- **Remote evidence model**: SSH sessions run inside the Terminal & SSH app, not the HAOS host — host processes and
  sockets are invisible (facts: root `KNOWLEDGE.md` §"Device SSH: sessions run in the Terminal & SSH app"). Assert
  process/socket-level behavior from the app's own log and network behavior from client probes on the dev host.

- **Stored options are user data**: written at first install and at save time only; update and rebuild preserve them;
  `config.yaml` default changes never reach existing installs. Facts: root `KNOWLEDGE.md` §"Supervisor: option schema
  quirks".

- **An uninstall purges stored options** in every case (the `--remove-config` flag only additionally deletes the app's
  `/data` config folder), so a reinstall always runs the app's default options. Any option set that would die with an
  uninstall is archived to a local backup file first (path printed) — that backup is the only surviving copy.

- The `deploy` task comments out the top-level `image:` key in the device copy so the Supervisor builds the image
  locally instead of pulling from GHCR (only `deploy` does this; `deploy-registry` reinstalls from the app repository
  and migrates the options).

- A repository-installed copy uses a hashed store slug (e.g. `f8b2d53d_nfs-server`) and conflicts on ports with a local
  install; `--replace` uninstalls it first. `--config` decides the previous options' fate — see `--help`.

- `deploy-registry` switches a device from the local `/local_apps` copy to the app-repository install (the hashed store
  slug is discovered from the device's store listing).

## test:live specifics

- Deploys (forwarding `--replace`) plus live checks. `--test-options` applies the app's test options
  (`.mise/tasks/test/live/<app>.yaml`, top-level key override) to the device app for the run only, with an options
  backup restored on exit.
- Per-app hook: `.mise/tasks/test/live/<app>.sh` with the contract `live_prepare`, `live_runtime_check`, `LIVE_*` vars —
  analogous to the lab hooks (skill `ha-app-lab-testing`). Apps without a hook get deploy plus state-wait only.
- Hooks may define their own env knobs; example: hd-idle's `LIVE_HDIDLE_LABEL_GLOB` selects the drives to exercise by
  filesystem label and generates the test options on the fly.
- The deploy runs as a mise `depends` edge with native arg forwarding (`{{ usage.* }}` templates; `--replace`
  conditionally via a Tera `{% if %}`). `mise tasks deps` hides the edge while the templates are unresolved (mise skips
  usage-templated deps until args are known); `mise run --dry-run` shows the rendered deploy command. Verified against
  released mise 2026.10.6, 2026.10.21 and 2026.10.23 (feature added upstream 2026.4, jdx/mise#8893; its historical
  silent-drop bug for omitted optional values, jdx/mise#13569, was fixed before 2026.10.6).
