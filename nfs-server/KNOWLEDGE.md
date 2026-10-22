# Development knowledge

Non-obvious facts about this app, collected so they don't have to be re-learned the hard way. Procedures (runtime
procedures, debugging playbook, extension guidance) live in the skill `nfs-server-runtime` (`.agents/skills/`);
repository-wide facts (supervisor rating formula, option-schema quirks, AppArmor mechanics, base-image shell gotchas) in
the repository-root `KNOWLEDGE.md`.

## Security rating — this app's ceiling

For the rating formula see the repository-root `KNOWLEDGE.md` §"Supervisor: app security rating". For this app: 5 + 1
(custom profile) − 1 (`SYS_ADMIN`) = **5** — the published-port +2 branch never applies (NFS needs its port), so 5 is
the design's ceiling; dropping `SYS_ADMIN` via the host-side nfsd mount road (TODO: "Upstream: host-side nfsd mount +
supervisor bind-mount") would reach 6.

## Security hardening — posture

A root container whose only high-risk capability is `SYS_ADMIN`, needed solely to mount the nfsd control filesystem in
the app's own procfs/network namespace — the nfsd kernel module is loaded by the kernel's mount-time autoload, outside
the app and its AppArmor label (root `KNOWLEDGE.md` §"AppArmor: mediation and profile mechanics"). A custom AppArmor
profile (`apparmor.txt`) enforces the mounts and the binary capabilities — no blanket `capability,` grant (§"AppArmor
profile — app-specific grants"). No `full_access`/`docker_api`/`host_pid`, so protection mode can stay enabled: the
`privileged` capability list applies regardless of protection mode, only those three keys are gated by it (supervisor
`docker/app.py`).

Why dropping `SYS_ADMIN` needs upstream work: the nfsd filesystem is instantiated per network namespace, so a
bridge-network app must mount it inside its own netns — a HAOS-side automount bind-mounted in would carry the host-netns
instance, mismatching the container's nfsd. The road is supervisor support for binding the host's `/proc/fs/nfsd` into
apps on demand plus `host_network: true`; the rating math cancels out (−1 host_network replaces −1 privileged) — the win
is zero capabilities, the cost is weaker network isolation.

## Export-cache and fsid semantics

Runtime semantics of the generated `/etc/exports` content (schema-side constraints are repository-wide: root
`KNOWLEDGE.md` §"Supervisor: option schema quirks"):

- The kernel keeps a single export cache entry per (path, client); duplicate lines resolve by *last line wins* —
  identical duplicates are noise, conflicting options silently apply whichever line is last (order-dependent). Hence
  duplicate (path, network) share entries are rejected: one option set applies per pair (the same path with different
  networks is legitimate).
- The per-share `fsid=` is assigned by config order (a counter): editing the share list renumbers the followers — NFSv4
  filehandles embed the fsid, so a renumber makes clients' old handles stale, including their recovery records after a
  share edit + app restart. An existing wart that only matters across share-list edits.
- Share inputs are constrained to whitespace- and backslash-free values (schema regexes, re-checked at runtime as
  defense in depth): `/etc/exports` is whitespace-separated (a newline in a value would inject an extra export line,
  parsed as a root export), and backslash paths would misjudge the mount-state detection (mountinfo escapes them as
  `\134`, `awk -v` processes escape sequences — §"Automatic mirror refresh (nfsd-watch)"). Paths: absolute, no empty
  components; `network`: the `exports(5)` machine-name charset; `options`: comma-separated export-option tokens.

## mountd and the pseudo file system root

- The kernel's nfsd resolves NFSv4 paths via export-cache upcalls serviced by `rpc.mountd` — without a running mountd,
  client mounts hang forever (NULL RPC is answered fine, which makes this hard to diagnose). v4 clients never use the
  MOUNT protocol, so the app runs `rpc.mountd -F -N 2 -N 3` (foreground, legacy listeners disabled — binds no ports,
  only services upcalls).
- The pseudo root must be exportable, and mountd's auto-created one (from exports rooted at `/`) cannot live on the
  container's overlayfs root — hence the app builds its own on `/data` (the persistent host-ext4 volume): bind mirrors
  of `/share` and `/media` at `/data/pseudo_root/{share,media}`, shares exported from the mirrored paths with their own
  client networks, the pseudo root itself read-only walkable for the union of all networks. Per-share options are
  enforced at the export boundary; client paths stay unchanged.
- A removed share leaves its mirror directory behind: nfsd-apply creates mirrors (`mkdir -p` + bind) but never removes
  orphaned ones — the empty directory of a deleted share stays visible to clients under the pseudo root (cosmetic wart;
  cleanup: `TODO.md`).
- Distinct numeric `fsid=` per export is essential: mountd's synthesized intermediate pseudo entries carry the
  filesystem's UUID, and filehandles keyed by that UUID are ambiguous once multiple exports share one filesystem (binds
  of the same fs) — they resolve back to the wrong export (mounts land on the read-only pseudo root → `EROFS` on write).
- The pseudo root needs no `crossmnt` (an NFSv3-era flag for seeing mounts beneath an export point): NFSv4 clients
  switch the export at mountpoint crossings regardless (`nfsd_cross_mnt` consults the export cache for any v4 client),
  and the pseudo entries mountd synthesizes carry `crossmnt` anyway.

## Grace period

Every restart cycle of the kernel server (`rpc.nfsd 0` + start) starts a grace period (default 90 s) during which
clients' write opens get `NFS4ERR_GRACE` and retry — writes appear to stall; a client-side write attempt in the window
fails with `EINTR` (busybox ash: `can't create …: Interrupted system call`). With the shipped `nfsdcld` tracker the
grace is only paid when client records exist: fresh boots skip it via the kernel's fast path (needs
`track_reclaim_completes`, set by the cld-v2 tracker init — `nfs4_state_start_net`'s skip path), and the grace ends
early once all recorded clients have reclaimed. The app's `--grace-time` default matches the lease time (before the
tracker shipped it was 10 s of pure dead time; see `nfsd-start`). Writes to `/proc/fs/nfsd/v4_end_grace` end the grace
regardless of any tracker (v6.18: the only guard is a running server, else `EBUSY`) — but that would deny late
reclaimers their window, so it is not a useful lever for a server that wants clients to recover.

## NFSv4 client state recovery (nfsdcld + per-netns rpc_pipefs)

NFSv4 is stateful: after a server restart, still-connected clients must reclaim their state (opens, locks, delegations)
during the grace period, for which the server needs a persistent store of client identities. The kernel provides three
mechanisms (`fs/nfsd/nfs4recover.c`): cld upcalls to a `nfsdcld` daemon, a UMH helper (`/sbin/nfsdcltrack`), and a
legacy recovery-directory store. The app ships the cld tracker (`nfsdcld` ships with the `nfs-utils` package the image
already installs; the daemon needs no capability grants — it prunes its own capability set at startup).

- The upcall pipe lives in the per-netns rpc_pipefs: the kernel creates `<rpc_pipefs>/nfsd/cld` inside the rpc_pipefs
  superblock registered for the server's network namespace (`rpc_get_sb_net(net)`), with the `nfsd/` subdirectory
  pre-created at mount. The container must mount one itself (`mount -t rpc_pipefs sunrpc <dir>`; `sunrpc` is built-in
  wherever the NFS client is, `CONFIG_NFS_FS=y` — every HAOS board); this mount (cont-init) is what makes the tracker
  work in a container.
- Ordering: `nfsd4_cld_tracking_init` waits only ~1 s (10 × 100 ms, `cld_running` = pipe has readers/writers) for the
  daemon to hold the pipe open. The s6-rc dependency (`nfsd` oneshot depends on the `cld` longrun) keeps the daemon
  ahead of `rpc.nfsd`; the daemon is race-tolerant anyway (inotify watch on the pipefs dir — it opens the pipe as soon
  as it appears).
- Fallback is silent degradation: a missing daemon/pipefs times the init out (`-ETIMEDOUT`) and the dispatcher falls
  back to the legacy trackers, which refuse non-init network namespaces (`net != init_net → -EINVAL`) — the "Unable to
  initialize client recovery tracking! (-2)" host-log line. The authoritative tracker messages ("NFSD: Using nfsdcld
  client tracking operations.", "no clients to reclaim, skipping NFSv4 grace period") go to the kernel log — the host
  journal/dmesg, NOT `ha apps logs`.
- Storage: `-s <dir>/main.sqlite` (per-epoch `rec-<epoch-hex>` tables plus a `grace` current/recovery-epoch table;
  unclaimed records survive only while their epoch is current or the recovery epoch), `-p` selects the pipefs root;
  nfsdcld 2.6.x answers GetVersion with upcall protocol version 2.
- Across a server recreation (connected client, held exclusive flock): the reloaded record makes the kernel run a grace
  period instead of skipping it, the client reclaims, the flock survives, the grace ends early once the reclaiming
  client is back; the store lives on `/data`, untouched by watcher cycles or app restarts.
- Residual unknown, NFSv4.0 early grace: the "all clients done reclaiming" printk only fires via RECLAIM_COMPLETE (the
  Linux client sends it only for v4.1, `fs/nfs/nfs4proc.c` `nfs40_reboot_recovery_ops`), and the laundromat cannot fire
  before the configured grace on its own — yet the observed grace end always followed the reclaim promptly; most
  plausible: reclaim events plus immediate laundromat kicks ending the grace once nobody is still reclaiming
  (`clients_still_reclaiming`). Only re-verify if this ever looks wrong.
- App wiring: cont-init mounts rpc_pipefs non-fatally (failure = degraded mode, the old short-grace behavior) and
  creates `/data/nfsdcld`; the `nfsd` oneshot depends on the `cld` longrun. AppArmor grants: §"AppArmor profile —
  app-specific grants".
- Mode 3 (legacy dir), should it ever matter: default dir hardcoded `/var/lib/nfs/v4recovery` (`user_recovery_dirname`),
  relocatable via `/proc/fs/nfsd/nfsv4recoverydir` before server start; inert for this containerized server (source:
  `fs/nfsd/nfs4recover.c`).

## nfsd control files reject `writev(2)`

`/proc/fs/nfsd/*` are procfs transaction files (`fs/nfsd/nfsctl.c`: old-style single-buffer `.write`, no `.write_iter`)
— the base image's bash `echo`/`printf` (single `writev(2)`; mechanism and workaround: root `KNOWLEDGE.md` §"HA base
image: shell gotchas", skill `ha-app-base-image`) fail with a misleading `write error: Invalid argument`, about the
syscall shape, not the content. Single-`write(2)` callers succeed: busybox `echo`, `cat`, and `rpc.nfsd`'s own writes
(why rpc.nfsd can configure the version set fine).

## `rpc.nfsd` is not a daemon

`rpc.nfsd` only configures the NFS server inside the kernel (version set, sockets, lease/grace time, kernel threads) and
then exits — upstream runs it as a `Type=oneshot` service; hence the app's s6-rc oneshot (`up`/`down` scripts in
`/etc/s6-overlay/scripts/`): a longrun would restart-loop forever, and readiness polling (`s6-notifyoncheck`) cannot
work for a process that is gone. Consequences for the version set:

- `rpc.nfsd` writes its default version set (NFSv3 + NFSv4) to the kernel unless told otherwise — `--no-nfs-version 3`
  keeps this app NFSv4-only; the outcome is logged and verified in `rootfs/etc/s6-overlay/scripts/nfsd-start`.
- `-N`/`-V` only accept 3 and 4: `--no-nfs-version 2` exits with `2: Unsupported version` (NFSv2 server support is not
  compiled into current kernels, `CONFIG_NFSD_V2` defaults to off).

The generated command line (`nfsd-apply` writes `/etc/nfsd.args`, `nfsd-start` executes it) is
`rpc.nfsd --no-nfs-version 3 --no-udp --host <app-ip> --lease-time <s> --grace-time <s> <threads>`: `--host` binds the
kernel server's sockets to the app's current IP — the address the Docker HEALTHCHECK probes (the recorded one,
§"Automatic mirror refresh (nfsd-watch)"), so a passing probe means the server is reachable where clients reach it;
`--no-udp` drops the UDP listeners a v4-only server has no use for (NFSv4 is TCP-only by design); the lease/grace
options: §"Grace period".

## The NFS version set is fixed while the server runs

Once a server instance exists in the kernel (i.e. `rpc.nfsd` started it), writes to `/proc/fs/nfsd/versions` fail with
`EBUSY`, and further `rpc.nfsd` invocations only adjust the thread count (version/socket configuration is skipped) —
stop the threads with `rpc.nfsd 0` first to reconfigure. Within a running container the version set lives in the
kernel's network namespace: it survives s6 service restarts and is only reset to the kernel defaults (everything
compiled-in: `+3 +4 +4.1 +4.2`) when the container — and with it the netns — is recreated.

## Automatic mirror refresh (nfsd-watch)

The app applies its share configuration once at boot: every share path under `/share`/`/media` gets a bind-mount mirror
under `/data/pseudo_root` (§"mountd and the pseudo file system root") and an `/etc/exports` line with a distinct numeric
fsid. Mirrors are private bind clones — outside the host's mount propagation chain — while HAOS bind-mounts `/share` and
`/media` into app containers with rslave propagation (supervisor `docker/app.py`, ref 2026-10): new host mounts
propagate into the container, but the mirrors never learn about it. An unplug leaves the mirror serving a detached
superblock clone (stale data; a replug would create two live superblocks for one block device — a data-integrity
hazard), and a replug at the same path keeps NFS serving the pre-unplug state until the app restarts. `nfsd-watch` (the
`hd-idle-watch` pattern: shared apply helper + poll loop + narrow restart) closes this; the change-cycle order, the
nfsd-apply modes and the mirror rebind ordering are procedures — skill `nfs-server-runtime`.

- Options are immutable while the app runs (the supervisor validates at save time and hands new options to the app only
  at its next start; root `KNOWLEDGE.md` §"Supervisor: option schema quirks"), so `/etc/exports` content never changes
  mid-run — only the mounts under the configured share paths do.
- Detection is a stateless invariant check over a single `/proc/self/mountinfo` snapshot: a share is clean iff the
  mirror serves the source path's current directory object (equal `dev:ino`, preserved across bind mounts) and the
  source's covering mount is the one recorded in the baseline state file (`/var/lib/nfs/mirrors.state`). The mount ID is
  essential: after a replug at the same path device and inode numbers are identical (same filesystem re-mounted), but
  every new mount instance gets a fresh mount ID — `stat`/`/proc/mounts` alone cannot see that re-mount. Among mounts
  stacked at one path the check picks the highest mount ID — the topmost mount is always the newest (IDs are allocated
  monotonically) and is also the object `stat` reports; mountinfo's file order is deliberately not relied on. Poll 30 s
  (`NFSD_WATCH_INTERVAL`, integer seconds, floored at 5; the logic is interval-agnostic), no udev wiring.
- Rebind ordering rationale: umounts deepest-first (a parent mirror with a child still mounted inside fails with `EBUSY`
  — the same rule `nfsd-stop` applies), binds shallowest-first (a child bind made before its parent's fresh bind ends up
  shadowed beneath it); mirrors are deduplicated per path (a path may back several shares across networks).
- Failure semantics: a failed check keeps the current configuration (options can't change mid-run — the guard is
  insurance); a failed apply or restart logs a warning and retries next tick — the baseline state file only advances on
  a successful apply, so detection is idempotent; the restart-pending marker is set before the teardown, so a failed
  apply also retries the server start even if detection has gone clean in between — the kernel server never stays down
  across ticks.
- App IP record: `nfsd-apply` re-detects the app IP per apply (the `--host` bind address of `/etc/nfsd.args`) and
  records it to `/var/lib/nfs/app.ip`; the Docker HEALTHCHECK reads that record instead of re-running its own detection
  pipeline per probe — and probes the address the server actually bound, which only diverges from the live pipeline in
  exotic interface-ordering corner cases (where the recorded value is the correct one to probe).
- Device-side verification of the real HAOS trigger path (rslave propagation of drive mounts under `/media`) is open —
  see `TODO.md`.

## AppArmor profile — app-specific grants

(Mediation mechanics — capability mediation, errno forensics, mount-rule grammar, network opt-in, supervisor profile
mechanics, the version-bump requirement — are repository-wide: root `KNOWLEDGE.md` §"AppArmor: mediation and profile
mechanics"; authoring procedure: skill `ha-app-apparmor`. Device-verified on HAOS 18.3 / OS Agent 1.14 / AppArmor
3.1.7.)

- The mounts are the profile's core — the four mount/umount rules in `apparmor.txt` for nfsd, rpc_pipefs, the per-share
  bind mirrors and their umounts. The `options=(bind)` conditioning is the grammar's new-mounts-only rule applied
  (fstype matching does not apply to binds); busybox `mount` passes the device string (`nfsd`, `sunrpc`) as the mount
  source, so pseudo-filesystem mounts are scoped by fstype, not source path.
- The top profile grants `sys_admin` (nfsd mount, bind mirrors); no `sys_module`, no modprobe exec rule, no
  `/lib/modules` access, no `kernel_modules: true` — mounting the nfsd fs triggers the kernel's module autoload in
  kernel context, outside the label.
- `deny network,` sub-profiles: rpc.nfsd (configures the kernel via procfs, creates no sockets) and nfsdcld (talks only
  to the kernel over the rpc_pipefs pipe). Top-profile network allowlist: `inet/inet6 stream/dgram` (bashio
  supervisor-API HTTP, DNS, the HEALTHCHECK `/dev/tcp` probe) and `netlink raw` (busybox `ip`'s rtnetlink address
  detection — easy to miss); the mountd sub-profile keeps inet/inet6 (it is an actual RPC server), exportfs too
  (RPC-based cache flushes).
- The nfsdcld sub-profile carries `capability setpcap,` — the daemon prunes its whole bounding set at startup
  (`prctl(PR_CAPBSET_DROP)` plus a final capset zeroing all sets; the generic self-capability subtlety is in root
  `KNOWLEDGE.md` §"AppArmor: mediation and profile mechanics"). Without the rule it exits in a restart loop ("Unable to
  prune capability 0 from bounding set: Operation not permitted"); the lab cannot catch this (no enforcement there). The
  grant only enables the self-pruning — the daemon ends up with zero capabilities anyway.
- The nfsd sub-profile's `capability net_bind_service,` is inert by construction — its `deny network,` means no socket
  can exist to bind (capability mediation is independent of the network class). It is kept deliberately: relaxing the
  network deny later must force a fresh decision on privileged-port binding rather than silently inheriting the grant
  (mountd's grant accompanies its network allowlist — its comment in `apparmor.txt`).
- Denial signatures seen with busybox `mount`: `mounting SRC on DST failed: Permission denied` (EACCES, mount-rule
  denial) vs `permission denied (are you root?)` (EPERM, capability denial).
