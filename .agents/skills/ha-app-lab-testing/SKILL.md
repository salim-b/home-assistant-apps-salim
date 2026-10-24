---
name: ha-app-lab-testing
description: How to run the full-fidelity boot lab and write per-app lab hooks (docker-args extension, runtime checks,
  fixture adapters) for Home Assistant apps, including hardware-behavior test discipline. Use before deploying any
  runtime-affecting change, or when adding or changing lab hooks.
---

# Boot lab

## When and how

Run for every runtime-affecting change. Invocation: `mise run lab [app] [--keep]`; usage via `mise run lab --help` (not
duplicated here). What it does: a fake Supervisor API serves the app's default options (adapted to the lab network), the
app container boots with its complete s6-rc tree, an app-provided runtime check runs, then a graceful stop. `--keep`
keeps containers/directories for debugging.

## Boot-only default

Apps without a hook get a boot-only lab (config fetch, full boot, graceful stop, exit code 0) — zero ceremony for new
apps (skill `ha-app-scaffolding`).

## Hook contract

`.mise/tasks/lab/<app>.sh` is sourced by the harness (env: `LAB_NET_NAME`, `LAB_TMPDIR`, `LAB_APP_IP`, `LAB_SUBNET`,
`LAB_SPINDOWN_DRIVES`):

- append to `lab_docker_args` (`lab_docker_args+=(…)` — do NOT overwrite it; the harness pre-seeds the `/data` volume);
- define `lab_runtime_check`.

The optional fixture adapter is a separate file `.mise/tasks/lab/<app>.py` defining `lab_adapt_fixture(options)` with
`LABNETWORK` as the subnet placeholder; the harness serves it to the fake API whenever the file exists. A generic
`LAB_FIXTURE_ENV` string from the invoking environment is forwarded to the fake-API container; adapters may parse it to
select fixture variants (hickory-dns uses it for per-protocol upstream pools:
`LAB_FIXTURE_ENV=upstreams=https mise run lab hickory-dns`). Convention over configuration — never place hook files
inside the app dir (app-dir contents get copied to devices by `deploy`).

Reference implementations: `.mise/tasks/lab/nfs-server.sh` and `nfs-server.py`.

## Hardware-behavior checks

The lab boots app containers `--privileged` on the lab host, so host-side hardware state interacts with tests:

- Run a read-only preflight sweep for OS-level power-management interference (udisks2 stored drive settings re-applied
  on hotplug, `/etc/hdparm.conf`, TLP `DISK_*`, smartd, powertop auto-tune, per-device runtime-PM `power/control`) and
  warn — see hd-idle's lab hook for the pattern. Mainstream distros ship none of these active by default; they are
  user-configured.
- Assert event-based, never "stays in state for N minutes": hardware state can legitimately change (a drive woken by
  unrelated IO is correct system behavior). Assert the event/transition — log lines, state probes right after a
  triggered command — rather than persistence of a state.
- Verify probes are side-effect-free: `hdparm -C` both races spin-down windows and can wake USB-attached drives;
  `smartctl -n standby` is designed not to. Device/bridge-specific findings live in the apps' `KNOWLEDGE.md`.
- Plain Docker exposes no `/dev/disk` udev symlink trees (HAOS binds the host `/dev` read-only into app containers):
  when an app's behavior depends on them, mirror it in the hook (`-v /dev/disk:/dev/disk:ro`). Facts: root
  `KNOWLEDGE.md` §"Supervisor: device access".
