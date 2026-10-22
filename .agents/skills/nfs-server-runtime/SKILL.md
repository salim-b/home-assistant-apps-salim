---
name: nfs-server-runtime
description: Runtime architecture, maintenance procedures, and debugging playbook for the nfs-server Home Assistant app
  — pseudo-root mirror design, nfsd-apply/nfsd-watch cycles, grace-period and client-recovery behavior, and how to
  diagnose on-device issues. Use before touching nfs-server runtime code, its s6 services, or when debugging the app on
  a device.
---

# nfs-server runtime

Facts: `nfs-server/KNOWLEDGE.md`, referenced below by section name; repository-wide facts: root `KNOWLEDGE.md`.
Procedures for lab/device testing and releases live in the skills `ha-app-lab-testing`, `ha-app-device-testing` and
`ha-app-workflow`; never duplicate mise task usage here — `mise run <task> --help`.

## Architecture orientation

- **NFSv4 only**: the server is started with `--no-nfs-version 3` (NFSv2 server support is not compiled into current
  kernels anyway); no `rpcbind`, no MOUNT protocol.
- **Pseudo root + bind-mount mirrors**: the container's overlayfs root is not NFS-exportable, so the app builds the
  NFSv4 pseudo file system root on `/data` (the persistent volume) at `/data/pseudo_root`: every share path under
  `/share`/`/media` is bind-mounted at `/data/pseudo_root<share-path>` (a private bind clone, outside the host's mount
  propagation chain) and the export lines point at the mirrored paths — client-visible paths stay unchanged.
- **`/etc/exports` generation**: the shared helper `/usr/bin/nfsd-apply` writes one line per (share, network) with a
  distinct numeric `fsid=` (per-apply counter), plus a read-only `fsid=0` pseudo-root entry per client network. Why
  numeric fsids are essential and how duplicate lines behave: §"mountd and the pseudo file system root", §"Export-cache
  and fsid semantics".
- The kernel server binds the app's IP (`rpc.nfsd --host`, generated into `/etc/nfsd.args` per apply, which also records
  it to `/var/lib/nfs/app.ip` for the healthcheck).

## Boot sequence and s6 services

Tree under `rootfs/etc/s6-overlay/` (wiring facts: root `KNOWLEDGE.md`, section "s6-overlay: user bundles live OUTSIDE
s6-rc.d"), in dependency order:

1. **cont-init** (`etc/cont-init.d/config.sh`): mounts the nfsd control filesystem at `/proc/fs/nfsd` (failure is fatal
   — the host kernel probably lacks the module), mounts **rpc_pipefs inside the app's network namespace** (non-fatal:
   without it the app runs degraded — no cross-restart client recovery), creates `/data/nfsdcld`, then runs
   `nfsd-apply --boot` (fatal on failure).
2. **`cld` longrun**: `nfsdcld -F -p /var/lib/nfs/rpc_pipefs -s /data/nfsdcld` — the NFSv4 client-recovery tracker
   daemon over the per-netns rpc_pipefs (§"NFSv4 client state recovery (nfsdcld + per-netns rpc_pipefs)").
3. **`mountd` longrun**: `rpc.mountd -F -N 2 -N 3` — foreground, legacy listeners off, binds no ports; services the
   kernel's export-cache upcalls (§"mountd and the pseudo file system root").
4. **`nfsd` oneshot** — up script `/etc/s6-overlay/scripts/nfsd-start`: `exportfs -a`, then the generated command line
   from `/etc/nfsd.args` (execute it as an array — see the invariant comment in nfsd-start for why the string form
   breaks). **`rpc.nfsd` is NOT a daemon**: it configures the in-kernel server (version set, sockets, lease/grace time,
   thread count) and exits, hence a oneshot (§"rpc.nfsd is not a daemon"); its down script `nfsd-stop` tears the server
   and the mirrors down, deepest mirror first.
5. **`nfsd-watch` longrun**: 30 s poll (override `NFSD_WATCH_INTERVAL`, floored at 5 s), runs
   `nfsd-apply --quiet --check` and cycles the kernel server on change (§"Automatic mirror refresh (nfsd-watch)").
6. **`nfsd-healthcheck`**: the Docker HEALTHCHECK probe — TCP connect to port 2049 at the recorded app IP, with a
   self-detection fallback; there is no daemon process to probe (rpc.nfsd exited).

## nfsd-apply modes and the watcher change cycle

`nfsd-apply [--boot] [--check] [--quiet]` — exit 0 success/unchanged, 3 (would) change, 1 failure. `--boot` is boot-time
and also creates missing share directories (uid/gid/permissions from the options); `--check` is a read-only baseline
replay of the state file `/var/lib/nfs/mirrors.state` (no option reads — options are immutable mid-run; a missing/empty
file counts as changed); `--quiet` silences narrative logs, errors always log.

On a detected change (`nfsd-watch/run`), in exactly this order:

1. `rpc.nfsd 0` — kernel threads down **first**: the running threads pin the mirrors' old superblocks, so the umounts
   would fail with `EBUSY` (the proven `nfsd-stop` order).
2. `exportfs -au` — unexport; no mirror teardown here (the next step redoes it in a fresh order).
3. `nfsd-apply` — rebind mirrors, rewrite `/etc/exports` + `/etc/nfsd.args`, record the new baseline and app IP.
4. `/etc/s6-overlay/scripts/nfsd-start` — re-export and restart the kernel server.

Mirror nesting rules (a share path can sit inside another share's mirror): **umounts run deepest-first** (unmounting a
parent mirror with a child still mounted inside fails with `EBUSY`) and **binds shallowest-first** (a child bind made
before its parent's fresh bind ends up shadowed beneath it); mirror paths are deduplicated (several shares may share one
path across networks).

The cycle drives the kernel server directly instead of restarting the s6-rc oneshot — s6-rc is not reentrant from inside
a service (a down/up cycle would deadlock). The restart-pending marker (`/var/lib/nfs/nfsd-restart-pending`) is set
*before* the teardown, so a failed apply still retries the start on the next tick: the kernel server never stays down
across ticks. A failed check keeps the current configuration. Every cycle restarts the server exactly like an app
restart — clients reclaim state during the grace period via the shipped tracker (§"Grace period", §"NFSv4 client state
recovery (nfsdcld + per-netns rpc_pipefs)").

## Debugging playbook

- **NFSv4 mounts hang** → no running `rpc.mountd`: the kernel's export-cache upcalls go unanswered while NULL RPC is
  answered fine, so client-side diagnosis looks healthy — §"mountd and the pseudo file system root".
- **First write stalls after an app/server restart** (`NFS4ERR_GRACE`; busybox ash prints
  `can't create …: Interrupted system call`) → the grace period (default 90 s); expected when client records exist,
  fresh boots skip it — §"Grace period".
- **Tracker/recovery messages missing from `ha apps logs`** → kernel nfsd logs go to the **host** journal/dmesg ("NFSD:
  Using nfsdcld client tracking operations.", "no clients to reclaim, skipping NFSv4 grace period"; a silent fallback to
  the legacy trackers logs "Unable to initialize client recovery tracking! (-2)" there) — §"NFSv4 client state recovery
  (nfsdcld + per-netns rpc_pipefs)".
- **`write error: Invalid argument` writing `/proc/fs/nfsd/*` from bash** → the writev(2) trap, not a content problem;
  use busybox `echo`/`cat`/rpc.nfsd — skill `ha-app-base-image`, §"nfsd control files reject writev(2)".
- **Version-set reconfiguration fails (`EBUSY`)** → the set is fixed while a server instance exists; `rpc.nfsd 0` first
  — §"The NFS version set is fixed while the server runs".
- **mount/umount denied** → distinguish EACCES (mount-rule denial) from EPERM (capability denial); HAOS produces no
  AppArmor audit logs — skill `ha-app-apparmor`, root `KNOWLEDGE.md` §"AppArmor: mediation and profile mechanics",
  app-specific grants §"AppArmor profile — app-specific grants".
- **State files** under `/var/lib/nfs/`: `mirrors.state` (detection baseline), `nfsd-restart-pending` (watcher marker),
  `app.ip` (healthcheck target), `nfsdcld/` (tracker sqlite store) — all safe to delete while the server is down.

## Extending

- **Adding a share option**: schema in `config.yaml` (+ `translations/en.yaml`), plumb it through `nfsd-apply`'s single
  jq pass (`[.path, .network, .options]` TSV — keep that contract and the whitespace/backslash invariants), and for
  server-level options the `/etc/nfsd.args` line. Options are user data: new keys need absent-key handling (root
  `KNOWLEDGE.md` §"Supervisor: option schema quirks"). Per-share export options just join the `options` field — mind the
  last-line-wins duplicate rule (§"Export-cache and fsid semantics").
- **Changing detection** (state-file format, `--check`): keep it a stateless replay over one mountinfo snapshot — the
  mount ID is the only signal that catches a re-mount at the same path (dev:ino cannot); clean ticks must stay
  log-silent. Facts: §"Automatic mirror refresh (nfsd-watch)".
- **Any runtime-affecting change**: full-fidelity lab boot first (`mise run lab nfs-server`, hook
  `.mise/tasks/lab/nfs-server.sh` — skill `ha-app-lab-testing`); device testing only on explicit user request (skill
  `ha-app-device-testing`). AppArmor changes additionally need a `config.yaml` version bump (the profile reloads on app
  update only — root `KNOWLEDGE.md` §"AppArmor: mediation and profile mechanics"). Releases: one version per branch plus
  a changelog entry (skill `ha-app-workflow`).
