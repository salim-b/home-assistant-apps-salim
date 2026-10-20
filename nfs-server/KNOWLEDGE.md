# Development knowledge

Non-obvious facts and gotchas learned while developing this app, collected here so they don't have to be re-learned the
hard way. App-specific facts only — repository-wide knowledge (supervisor rating formula, option-schema quirks, device
access, AppArmor mechanics, base-image shell gotchas, lab testing) lives in the repository-root `KNOWLEDGE.md`.

## Security rating — this app's ceiling

For the rating *formula* (every branch, sources, the store-vs-installed delta and the unreachable `signed` +1) see the
repository-root `KNOWLEDGE.md`.

For this app (0.5.0): 5 + 1 (custom profile) − 1 (`SYS_ADMIN`) = **5** — the published-port +2 branch never applies (NFS
needs its port), so **5 is the design's ceiling**; dropping `SYS_ADMIN` via a host-side nfsd mount (the TODO task
"Upstream: host-side nfsd mount + supervisor bind-mount") would reach 6.

## Export-cache and fsid semantics of the per-share configuration

(The schema-side constraints — `match()` search semantics, the DSL's missing uniqueness construct and the
defense-in-depth pattern — are repository-wide, see the repository-root `KNOWLEDGE.md`.)

Runtime semantics of share-list configuration (why duplicates would silently misbehave): the kernel keeps a single
export cache entry per (path, client); duplicate `/etc/exports` lines for it are resolved by *last line wins* –
identical duplicates are only noise, conflicting options silently apply whichever line is last, order-dependent. Also
note the per-share `fsid=` is assigned by config order (a counter): removing/adding shares renumbers the followers – an
existing wart that only matters across share-list edits (NFSv4 filehandles embed the fsid; a renumber makes clients' old
handles stale, including their recovery records after a share edit + app restart).

## Security hardening — posture and what is left

Current posture (0.4.0): a root container whose only high-risk capability is `SYS_ADMIN`, needed solely to mount the
nfsd control filesystem in the app's own procfs/network namespace (the nfsd kernel module itself is loaded by the
kernel's mount-time autoload, outside the app). A custom AppArmor profile (`apparmor.txt`) enforces the mounts and the
binary capabilities – there is no blanket `capability,` grant. No `full_access`/`docker_api`/ `host_pid`, so
**protection mode can stay enabled**: the `privileged` capability list applies regardless of protection mode; only those
three keys are gated by it (supervisor `docker/app.py`).

Rating ceiling: **5 today** (see the rating section above). The only remaining lever is dropping `SYS_ADMIN` (→ 6), and
with the current supervisor feature set that is only possible via the **host-side nfsd mount + supervisor bind-mount
road** (the TODO task "Upstream: host-side nfsd mount"): the app needs the nfsd control filesystem mounted *in its own
network namespace* – the filesystem is instantiated per netns, so a mere HAOS-side automount does not help a
bridge-network app (its bind-mount would carry the host-netns instance, mismatching the container's nfsd). That is why
supervisor support (bind the host's `/proc/fs/nfsd` into apps on demand) plus `host_network: true` would be required.
Tradeoff, and the reason this is exploratory upstream work rather than a local change: the rating math cancels out (−1
host_network replaces −1 privileged) – the real win is zero capabilities, the real cost is weaker network isolation.
Everything else in the formula is either incompatible with the app (the no-ports +2 requires zero published ports) or
unreachable for any app (the signed +1: `AppModel.signed` is a stub).

## NFSv4 needs `rpc.mountd` and an exportable pseudo file system root

The kernel's nfsd resolves NFSv4 paths via export-cache upcalls that are serviced by `rpc.mountd` – without a running
mountd, client mounts hang forever (NULL RPC is answered fine, which makes this hard to diagnose). v4 clients never use
the MOUNT protocol, so the app runs `rpc.mountd -F -N 2 -N 3` (foreground, both legacy listeners disabled → it binds no
network ports and only services upcalls).

Terminology: RFC 8881 §7.3 (and RFC 7530 §7.5) call the mechanism the "(Server) Pseudo File System"; "pseudo-root" is
the common informal name for its root. It is an NFSv4-family mechanism – NFSv2/3 have no server-side namespace assembly
(clients mount each export via the MOUNT protocol, flat).

The pseudo file system root must be exportable: mountd auto-creates it from the export paths rooted at `/`, but the app
container's overlayfs root cannot be exported. Hence the app builds its own one on `/data` (the app's persistent,
host-ext4 volume): bind mounts of `/share` and `/media` at `/data/pseudo_root/{share,media}`, shares exported from their
mirrored paths (`/data/pseudo_root<share-path>`) with **distinct numeric `fsid=`** and their own client networks (the
pseudo file system root gets read-only walk access for the union of all networks). Client paths stay unchanged.
Consequences:

- Per-share options (`rw`/`ro`, squashing, …) are enforced at the export boundary – verified end-to-end including nested
  shares and multiple networks.
- Numeric fsids are essential: mountd's synthesized intermediate pseudo root entries carry the filesystem's UUID, and
  filehandles keyed by that UUID are ambiguous once multiple exports share one filesystem (binds of the same fs) – they
  resolve back to the wrong export (observed: mounts land on the ro pseudo root → `EROFS` on write).
- The pseudo root itself needs no `crossmnt` (an NFSv3-era flag for seeing mounts beneath an export point): NFSv4
  clients switch the export at mountpoint crossings regardless (`nfsd_cross_mnt` consults the export cache for any v4
  client), and the pseudo entries mountd synthesizes for the path components carry `crossmnt` anyway.
- Every restart cycle of the kernel server (`rpc.nfsd 0` + start) starts a grace period (default 90 s) during which
  clients' write opens get `NFS4ERR_GRACE` and retry – writes appear to stall. With the shipped `nfsdcld`-based recovery
  tracking (see the recovery section below), this only happens when client records exist (fresh boots skip the grace via
  the kernel's fast path, and the grace ends early once all recorded clients have reclaimed).

## The grace period stalls clients' first writes after every (re)start

Measured in the lab: after an app (re)start, mounts are instant, but the **first write open waits out the grace period**
(`NFS4ERR_GRACE`, client retries; ~104 s wall time with backoff at the kernel's 90 s default). Client-side manifestation
of a write attempt during the grace window (observed on the device with the short grace): the open fails with `EINTR` –
busybox ash prints it as `can't create …: Interrupted system call`.

Before the recovery tracking shipped, this was pure dead time (no client records existed), so the app defaulted
`--grace-time` to 10 s; with the tracker the grace is only paid when there is state to reclaim, and the default now
matches the lease time (see `nfsd-start`). The kernel's own skip path needs reclaim-complete tracking
(`track_reclaim_completes`, set by the cld-v2 tracker init; see `nfs4_state_start_net`'s `skip_grace`) – reachable since
the `nfsdcld` tracker shipped. Writes to `/proc/fs/nfsd/v4_end_grace` end the grace regardless of any tracker (v6.18:
the only guard is a running server – `nn->nfsd_serv`, else `EBUSY`; the older kernel's `nfsd4_force_end_grace` tracker
gate is gone) – but that would deny late reclaimers their window, so it is not a useful lever for a server that wants
clients to recover.

## NFSv4 client state recovery works in-container (shipped: `nfsdcld` + per-netns rpc_pipefs)

NFSv4 is stateful: after a *server* restart, still-connected clients must reclaim their state (opens, locks,
delegations) during the grace period. For that, the server needs a persistent store of client identities – the "client
recovery tracking". The kernel provides three mechanisms (`fs/nfsd/nfs4recover.c`):

1. **cld tracker**: upcalls to a `nfsdcld` daemon over rpc_pipefs; the daemon keeps its own (sqlite) store.
2. **UMH helper**: spawns `/sbin/nfsdcltrack` via the usermode helper.
3. **legacy**: filesystem store in a recovery directory.

The app ships mode 1 (`nfsdcld` comes with the `nfs-utils` package the image already installs, including its sqlite
runtime; the daemon needs no capability grants – it prunes its own capability set at startup). All of the following was
verified in privileged containers against the real host kernel (kernel v6.18 sources checked for the mechanisms):

- **The upcall pipe lives in the per-netns rpc_pipefs**: the kernel creates `<rpc_pipefs>/nfsd/cld` inside the
  rpc_pipefs superblock registered for the server's network namespace (`rpc_get_sb_net(net)`); the `nfsd/` subdirectory
  is pre-created by the kernel when rpc_pipefs mounts. The container must therefore mount one itself
  (`mount -t rpc_pipefs sunrpc <dir>`) – `sunrpc` is built-in wherever the NFS *client* is (`CONFIG_NFS_FS=y`), i.e. on
  every HAOS board. Mounting it into the app (cont-init) is what makes the whole tracker work in a container.
- **Ordering**: `nfsd4_cld_tracking_init` waits only ~1 s (10 × 100 ms, `cld_running` = the pipe has readers/writers)
  for the daemon to hold the pipe open. The s6-rc dependency (`nfsd` oneshot depends on the `cld` longrun) keeps the
  daemon ahead of `rpc.nfsd`; the daemon itself is race-tolerant (inotify watch on the pipefs dir – it opens the pipe as
  soon as it appears), so even a slightly late daemon start is fine.
- **Fallback is silent degradation**: if the daemon/pipefs is missing, the tracker init times out (`-ETIMEDOUT`) and the
  dispatcher falls back to the legacy trackers, which refuse non-init network namespaces (`net != init_net → -EINVAL`) –
  the known "Unable to initialize client recovery tracking! (-2)" host-log line. The kernel log carries the
  authoritative tracker messages ("NFSD: Using nfsdcld client tracking operations." / "no clients to reclaim, skipping
  NFSv4 grace period") – visible in the *host* journal / `dmesg`, NOT in `ha apps logs`.
- **Storage**: `-s <dir>/main.sqlite` (per-epoch record tables `rec-<epoch-hex>` plus a `grace` current/recovery epoch
  table; unclaimed records only survive while their epoch is current or the recovery epoch). `-p` selects the pipefs
  root. nfsdcld 2.6.x answers GetVersion with upcall protocol version 2.
- **End-to-end verified** (fresh netns + persistent sqlite volume, client holding an open fd + exclusive flock across
  the server recreation): the reloaded record makes the kernel run a grace period instead of skipping ("starting
  300-second grace period"), the client's state manager renews → detects the reboot → reclaims
  (`nfs4_schedule_lease_recovery` traces), a held exclusive flock **survives the restart** (contested by a second client
  afterwards: still blocked), and the grace **ends early** once the reclaiming client is back (the daemon's GraceDone
  downcall arrives well before the configured grace is up). Fresh boots with no records log "no clients to reclaim,
  skipping NFSv4 grace period" – the kernel's own fast path, now reachable because `track_reclaim_completes` is set by
  the cld tracker init (`nfs4_cld_state_init`).
- **Residual unknown**: the exact kernel path that ends the grace early for NFSv4.0 reclaimers. The "all clients done
  reclaiming, ending NFSv4 grace period" printk only fires via `inc_reclaim_complete` (the RECLAIM_COMPLETE op – the
  Linux client sends it only for NFSv4.1, confirmed in `fs/nfs/nfs4proc.c`'s `nfs40_reboot_recovery_ops`), and the
  laundromat cannot fire before the configured grace on its own schedule – yet the observed GraceDone always followed
  the reclaim promptly. Most plausible: reclaim events (`somebody_reclaimed = true` in the reclaim-lock path) plus the
  immediate laundromat kicks (`mod_delayed_work(..., 0)` sites) ending the grace once nobody is still reclaiming
  (`clients_still_reclaiming`). Only re-verify if this behavior ever looks wrong.

App wiring: cont-init mounts rpc_pipefs (non-fatal on failure – degraded mode = the old short-grace behavior) and
creates `/data/nfsdcld`; the s6-rc `cld` longrun execs `nfsdcld -F -p /var/lib/nfs/rpc_pipefs -s /data/nfsdcld`; the
`nfsd` oneshot depends on it. AppArmor: the rpc_pipefs mount rule plus an `nfsdcld` sub-profile (`deny network,` – the
daemon makes no sockets; it prunes its own capability set at startup and needs a `capability setpcap` rule for that, see
the AppArmor gotchas below).

Facts for mode 3, should it ever matter: the default recovery dir is hardcoded as `/var/lib/nfs/v4recovery`
(`user_recovery_dirname`); it can be relocated at runtime via the `/proc/fs/nfsd/nfsv4recoverydir` control file (must be
set before the server starts). The app does *not* create that dir: for the containerized server it would be inert.

## nfsd control files reject `writev(2)` (`EINVAL`)

`/proc/fs/nfsd/*` are procfs *transaction files* (`fs/nfsd/nfsctl.c`, `transaction_ops`): old-style single-buffer
`.write`, no `.write_iter` — so the base image's bash `echo`/`printf` (which emit a single `writev(2)`; the mechanism
and the general workaround are repository-wide, see the repository-root `KNOWLEDGE.md`) fail against them with a
misleading `write error: Invalid argument` — about the syscall shape, not the content (e.g. referencing non-available
NFS versions is irrelevant). Single- `write(2)` callers succeed: busybox `echo`, `cat`, and `rpc.nfsd`'s own writes
(which is why `rpc.nfsd` can configure the version set fine).

## `rpc.nfsd` is not a daemon

`rpc.nfsd` only configures the NFS server inside the kernel (version set, sockets, lease/grace time, kernel threads) and
then exits – upstream runs it as a `Type=oneshot` service. That's why the app runs it as an s6-rc `oneshot` (`up`/`down`
scripts in `/etc/s6-overlay/scripts/`): a `longrun` would restart-loop forever because the process exits immediately,
and readiness polling (`s6-notifyoncheck`) cannot work for a process that is gone.

Consequences for the NFS version set:

- `rpc.nfsd` writes its default version set (NFSv3 and NFSv4) to the kernel unless told otherwise – `--no-nfs-version 3`
  is what keeps this app's setup NFSv4-only. The outcome is logged and verified in
  `rootfs/etc/s6-overlay/scripts/nfsd-start`.
- `-N`/`-V` only accept 3 and 4: passing `--no-nfs-version 2` exits with `2: Unsupported version` (NFSv2 server support
  is not compiled into current kernels anyway, `CONFIG_NFSD_V2` defaults to off).

## The NFS version set is fixed while the server runs

Once an NFS server instance exists in the kernel (i.e. `rpc.nfsd` started it), writes to `/proc/fs/nfsd/versions` fail
with `EBUSY`, and further `rpc.nfsd` invocations only adjust the thread count anymore (version/socket configuration is
skipped). Stop the threads with `rpc.nfsd 0` first to reconfigure.

Within a running container the version set lives in the kernel's network namespace: it survives s6 service restarts and
is only reset to the kernel defaults (everything compiled-in: `+3 +4 +4.1 +4.2`) when the container – and with it the
network namespace – is recreated.

## Automatic mirror refresh (nfsd-watch)

The app applies its share configuration once at boot: every share path under `/share`/`/media` gets a **bind-mount
mirror** under `/data/pseudo_root` (the container's overlayfs root is not NFS-exportable) and an `/etc/exports` line
with a distinct numeric fsid. Mirrors are private bind clones made at bind time — they are outside the host's mount
propagation chain. HAOS bind-mounts `/share` and `/media` into app containers with **`rslave` propagation**
(`supervisor/docker/app.py` binds `MountBindOptions(propagation=PropagationMode.RSLAVE)`, verified against supervisor
ref 2026-10), so new host mounts propagate *into* the running container — but the mirrors never learn about it:

- **Unplug** (HAOS unmounts the drive): the mirror keeps serving the detached superblock clone — stale data stays
  exported over NFS, and after a replug two live superblocks would exist for one block device (a data-integrity hazard),
  so the mirror must be dropped and re-bound.
- **Replug at the same path**: the drive remounts on top of the path, but the mirror still binds the pre-unplug state;
  NFS keeps serving stale content until the app restarts.

`nfsd-watch` (s6-rc longrun, the `hd-idle-watch` pattern: shared apply helper + poll loop + narrow restart) closes this.
App options are immutable while the app runs (the supervisor validates at save time and hands new options to the app
only at its next start), so `/etc/exports` content never changes mid-run — only the *mounts under* the configured share
paths do. `/usr/bin/nfsd-apply` is the shared generator (cont-init calls it at boot with `--boot`; the watcher
re-invokes it), with three modes: `--boot` (create missing share directories), `--check` (read-only change detection,
exit 3 = changed), `--quiet` (no per-tick narrative logs).

**Detection** is a stateless invariant check over `/proc/self/mountinfo`: a share is clean iff the mirror serves the
source path's current directory object (equal `dev:ino`, preserved across bind mounts) *and* the source's covering mount
is the one recorded in the baseline state file (`/var/lib/nfs/mirrors.state`). The mount ID is essential: after a replug
at the same path the device and inode numbers are identical (same filesystem re-mounted), but the kernel assigns every
new mount instance a fresh mount ID — `stat`/`/proc/mounts` alone cannot see that re-mount. Among mounts stacked at one
path the check picks the highest mount ID — the topmost mount is always the newest (IDs are allocated monotonically),
which is also the object `stat` reports; mountinfo's file order is a kernel-internal detail and is deliberately not
relied on. The watcher polls every 30 s; no udev wiring, matching the trigger-path simplicity (a drive mount appearing
under `/media` is the whole event).

The detection's matching is exact only for whitespace- and backslash-free values, so the configuration validation
rejects both (`/proc/mounts` and mountinfo escape backslashes as `\134`, and `awk -v` processes escape sequences — a
backslash-containing path would misjudge the mount checks).

**The change cycle** deliberately drives the kernel server directly instead of restarting the s6-rc oneshot (s6-rc is
not reentrant from inside a service, and a down/up would deadlock; the oneshot stays "up" and container shutdown still
runs its down script):

1. `rpc.nfsd 0` — threads down *first*, releasing the kernel's export/file-handle cache pins on the mirrors (the proven
   `nfsd-stop` order; without it the mirror umounts fail with `EBUSY`).
2. `exportfs -au` — unexport (without the `nfsd-stop` mirror teardown, which the next step redoes in a fresh order).
3. `nfsd-apply` — rebind mirrors and rewrite `/etc/exports`.
4. `/etc/s6-overlay/scripts/nfsd-start` — re-export and restart the kernel server.

Mirror rebinds must respect nesting (a share path can sit inside another share's mirror): **umounts run deepest-first**
(unmounting a parent mirror with a child mirror still mounted fails with `EBUSY` — the same rule `nfsd-stop` applies to
its teardown) and **binds shallowest-first** (a child bind made before its parent's fresh bind would end up shadowed
beneath it). Mirrors are deduplicated per path (a path may appear in several shares, e.g. different networks).

**Failure semantics**: a failed check keeps the current configuration (like `hd-idle-watch`, options can't change
mid-run, so a check failure is a can't-happen guarded for insurance); a failed apply or restart logs a warning and
retries next tick — the baseline state file only advances on a successful apply, so detection is idempotent. The
restart-pending marker is set when a cycle begins (before the server is torn down), so a failed apply also retries the
server start on the next tick even if the detection state has gone clean in between (umounts succeeded, rebind failed,
drive detached) — the kernel server can never stay down across ticks. The watcher logs one info line per detected change
("Share mount state changed…") and is silent on clean ticks.

Grace-period interplay: each watcher cycle restarts the kernel server exactly like an app restart — connected clients
reclaim state during the grace period via the shipped `nfsdcld` tracker (see the sections above; the tracker's store
lives on `/data` and is untouched by the cycle).

Lab verification (`.mise/tasks/lab/nfs-server.sh`, in-container simulation — the lab app runs privileged, so a bind over
the share path stands in for a replug and its umount for an unplug; the real trigger path is
supervisor-source-verified): replug content switch within the poll interval, unplug → empty export (the stale-serving
regression check), quiet ticks (no restart without a change), and the unaffected-share check. Device-side verification
of the real HAOS trigger path (rslave propagation of drive mounts under `/media`) is a TODO.

## AppArmor profile — nfs-server-specific notes

(Mediation mechanics — capability mediation, errno forensics, mount-rule grammar, network opt-in, ioctl mediation,
supervisor profile mechanics, the version-bump iteration requirement, kernel-context module autoload — are
repository-wide, see the repository-root `KNOWLEDGE.md`. Device-verified 2026-10, HAOS 18.3 / OS Agent 1.14 / AppArmor
3.1.7.)

- The top profile grants `sys_admin` (nfsd mount, per-share bind mirrors); the container's CapEff (`00000000a82525fb` on
  the device, before `kernel_modules` was dropped) already contained it via `privileged: [SYS_ADMIN]`.
- The mounts are the profile's core; reference rules in `apparmor.txt`: `mount fstype=(nfsd) nfsd -> /proc/fs/nfsd/,`,
  `mount fstype=(rpc_pipefs) sunrpc -> /var/lib/nfs/rpc_pipefs/,`,
  `mount options=(bind) /{share,media}{,/**} -> /data/pseudo_root{,/**},`, `umount /data/pseudo_root{,/**},` (the
  `options=(bind)` conditioning is the grammar's new-mounts-only rule applied).
- The nfsdcld sub-profile carries `capability setpcap,` — the daemon prunes its whole bounding set at startup (the
  generic self-capability-management subtlety is in the repository-root `KNOWLEDGE.md`; without the rule it exits in a
  restart loop: "Unable to prune capability 0 from bounding set: Operation not permitted").
- `deny network,` sub-profiles: rpc.nfsd (configures the kernel via procfs, creates no sockets) and nfsdcld (talks only
  to the kernel over the rpc_pipefs pipe). The top profile's allowlist: `network inet/inet6 stream/dgram` (bashio
  supervisor-API HTTP, DNS, the HEALTHCHECK `/dev/tcp` probe) and `network netlink raw` (busybox `ip`'s rtnetlink
  address detection — easy to miss).
- The kernel's mount-time module autoload was device-verified for nfsd (fresh boot with the module unloaded: mount
  succeeds, NFS serves, client roundtrip passes) — hence no `sys_module`, no modprobe exec rule, no `/lib/modules`
  access, no `kernel_modules: true`.
- Observed denial messages (busybox `mount`): `mounting SRC on DST failed: Permission denied` (**EACCES**, mount-rule
  denial) and `permission denied (are you root?)` (**EPERM**, capability denial) — the general forensics toolkit (no
  AppArmor audit logs on HAOS!) is in the repository-root `KNOWLEDGE.md`.
