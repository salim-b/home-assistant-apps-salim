# Development knowledge

Non-obvious facts and gotchas learned while developing this app, collected
here so they don't have to be re-learned the hard way.

## Supervisor security rating: formula and our ceiling

`supervisor/apps/utils.py::rating_security` (read at supervisor 2026.09.3,
re-verify before relying on it) starts at **5** (1–8 clamp) and adjusts:

- AppArmor: disabled −1 / custom profile **+1** (not +2 — easy to miscount)
- Ingress +2; *else* no host network **and no mapped ports** +2; *else*
  supervisor-auth-API access +1
- signed +1 — **unreachable**: `AppModel.signed` is a hardcoded `False`
  stub ("Currently no signing support"; verified in 2026.09.3 and
  2026.10.1). Our images *are* cosign-signed (workflow keyless signing;
  `cosign verify` passes), but supervisor cannot credit it yet.
- High-risk capabilities (`SYS_ADMIN`, `SYS_MODULE`, …) or
  `kernel_modules` −1 (single deduction for the whole branch)
- `hassio_role` manager/admin −1/−2; host networks −1 (net) / −2 (pid) /
  −1 (uts+SYS_ADMIN); docker-API or full access → forced to 1

For this app (0.5.0): 5 + 1 (profile) − 1 (`SYS_ADMIN`) = **5** — the
published-port +2 branch never applies (NFS needs its port), so **5 is the
design's ceiling**; dropping `SYS_ADMIN` via a host-side nfsd mount (the
TODO task "Upstream: host-side nfsd mount + supervisor bind-mount") would
reach 6.

The rating differs between the store listing and an installed app —
expected, not a device quirk: `AppModel.apparmor` (supervisor
`apps/model.py`) returns `SECURITY_PROFILE` only if a profile *for this
app is already installed on the host* (`sys_host.apparmor.exists(slug)`
checks the supervisor's AppArmor profile store, which
`install_apparmor()` fills during app install/update). A store-listed app
has no profile on the host yet → `SECURITY_DEFAULT` → the AppArmor branch
contributes 0 → the store shows 4 for this app (5 − 1 `SYS_ADMIN`), and 5
only once installed. The same +1 delta appears for every app shipping a
custom profile (e.g. the official dnsmasq app). It is *not* related to
AppArmor support on the device — hosts without AppArmor support don't
show different ratings; they reject installing such apps outright
(`UnsupportedReason.APPARMOR`).

## Supervisor option schema `match()` quirks

`match(...)` regexes in `config.yaml` schema fields use voluptuous `Match`
(*search* semantics, not fullmatch) – always anchor with explicit `^…$`.
Also, the supervisor's schema-element parser breaks on literal `\t`/`\n`
inside YAML double-quoted scalars (they become real control characters) –
express whitespace classes via `\\s` instead. Verified against the
supervisor `AppOptions` validation code at the pinned ref (see
`.mise/tasks/validate.py`).

The options DSL (`supervisor/apps/options.py` `RE_SCHEMA_ELEMENT`) has **no
uniqueness construct** – list-of-objects options are validated entry by
entry, cross-entry constraints cannot be expressed (the supervisor itself
uses `vol.Unique()`, but only in its *own* app-config schema, e.g. the
`machine` list). Cross-entry guards therefore belong in the app's runtime
scripts (defense in depth pattern): config.sh rejects duplicate
(path, network) share entries at startup.

Related runtime semantics (why duplicates would silently misbehave): the
kernel keeps a single export cache entry per (path, client); duplicate
`/etc/exports` lines for it are resolved by *last line wins* – identical
duplicates are only noise, conflicting options silently apply whichever
line is last, order-dependent. Also note the per-share `fsid=` is assigned
by config order (a counter): removing/adding shares renumbers the
followers – an existing wart that only matters across share-list edits
(NFSv4 filehandles embed the fsid; a renumber makes clients' old handles
stale, including their recovery records after a share edit + app restart).

## Security hardening — posture and what is left

Current posture (0.4.0): a root container whose only high-risk capability
is `SYS_ADMIN`, needed solely to mount the nfsd control filesystem in the
app's own procfs/network namespace (the nfsd kernel module itself is loaded
by the kernel's mount-time autoload, outside the app). A custom AppArmor
profile (`apparmor.txt`) enforces the mounts and the binary capabilities –
there is no blanket `capability,` grant. No `full_access`/`docker_api`/
`host_pid`, so **protection mode can stay enabled**: the `privileged`
capability list applies regardless of protection mode; only those three
keys are gated by it (supervisor `docker/app.py`).

Rating ceiling: **5 today** (see the rating section above). The only
remaining lever is dropping `SYS_ADMIN` (→ 6), and with the current
supervisor feature set that is only possible via the **host-side nfsd
mount + supervisor bind-mount road** (the TODO task "Upstream: host-side
nfsd mount"): the app needs the nfsd control filesystem mounted *in its own
network namespace* – the filesystem is instantiated per netns, so a mere
HAOS-side automount does not help a bridge-network app (its bind-mount
would carry the host-netns instance, mismatching the container's nfsd).
That is why supervisor support (bind the host's `/proc/fs/nfsd` into apps
on demand) plus `host_network: true` would be required. Tradeoff, and the
reason this is exploratory upstream work rather than a local change: the
rating math cancels out (−1 host_network replaces −1 privileged) – the real
win is zero capabilities, the real cost is weaker network isolation.
Everything else in the formula is either incompatible with the app (the
no-ports +2 requires zero published ports) or unreachable for any app (the
signed +1: `AppModel.signed` is a stub).

## NFSv4 needs `rpc.mountd` and an exportable pseudo file system root

The kernel's nfsd resolves NFSv4 paths via export-cache upcalls that are
serviced by `rpc.mountd` – without a running mountd, client mounts hang
forever (NULL RPC is answered fine, which makes this hard to diagnose). v4
clients never use the MOUNT protocol, so the app runs
`rpc.mountd -F -N 2 -N 3` (foreground, both legacy listeners disabled → it
binds no network ports and only services upcalls).

Terminology: RFC 8881 §7.3 (and RFC 7530 §7.5) call the mechanism the
"(Server) Pseudo File System"; "pseudo-root" is the common informal name for
its root. It is an NFSv4-family mechanism – NFSv2/3 have no server-side
namespace assembly (clients mount each export via the MOUNT protocol, flat).

The pseudo file system root must be exportable: mountd auto-creates it from
the export paths rooted at `/`, but the app container's overlayfs root cannot
be exported. Hence the app builds its own one on `/data` (the app's
persistent, host-ext4 volume): bind mounts of `/share` and `/media` at
`/data/pseudo_root/{share,media}`, shares exported from their mirrored paths
(`/data/pseudo_root<share-path>`) with **distinct numeric `fsid=`** and their
own client networks (the pseudo file system root gets read-only walk access
for the union of all networks). Client paths stay unchanged. Consequences:

- Per-share options (`rw`/`ro`, squashing, …) are enforced at the export
  boundary – verified end-to-end including nested shares and multiple
  networks.
- Numeric fsids are essential: mountd's synthesized intermediate pseudo root
  entries carry the filesystem's UUID, and filehandles keyed by that UUID
  are ambiguous once multiple exports share one filesystem (binds of the
  same fs) – they resolve back to the wrong export (observed: mounts land
  on the ro pseudo root → `EROFS` on write).
- The pseudo root itself needs no `crossmnt` (an NFSv3-era flag for seeing
  mounts beneath an export point): NFSv4 clients switch the export at
  mountpoint crossings regardless (`nfsd_cross_mnt` consults the export
  cache for any v4 client), and the pseudo entries mountd synthesizes for
  the path components carry `crossmnt` anyway.
- Every restart cycle of the kernel server (`rpc.nfsd 0` + start) starts a
  grace period (default 90 s) during which clients' write opens get
  `NFS4ERR_GRACE` and retry – writes appear to stall. With the shipped
  `nfsdcld`-based recovery tracking (see the recovery section below), this
  only happens when client records exist (fresh boots skip the grace via the
  kernel's fast path, and the grace ends early once all recorded clients
  have reclaimed).

## The grace period stalls clients' first writes after every (re)start

Measured in the lab: after an app (re)start, mounts are instant, but the
**first write open waits out the grace period** (`NFS4ERR_GRACE`, client
retries; ~104 s wall time with backoff at the kernel's 90 s default).
Client-side manifestation of a write attempt during the grace window
(observed on the device with the short grace): the open fails with `EINTR`
– busybox ash prints it as `can't create …: Interrupted system call`.

Before the recovery tracking shipped, this was pure dead time (no client
records existed), so the app defaulted `--grace-time` to 10 s; with the
tracker the grace is only paid when there is state to reclaim, and the
default now matches the lease time (see `nfsd-start`). The kernel's own
skip path needs reclaim-complete tracking (`track_reclaim_completes`, set
by the cld-v2 tracker init; see `nfs4_state_start_net`'s `skip_grace`) –
reachable since the `nfsdcld` tracker shipped. Writes to
`/proc/fs/nfsd/v4_end_grace` end the grace regardless of any tracker
(v6.18: the only guard is a running server – `nn->nfsd_serv`, else
`EBUSY`; the older kernel's `nfsd4_force_end_grace` tracker gate is gone)
– but that would deny late reclaimers their window, so it is not a useful
lever for a server that wants clients to recover.

## NFSv4 client state recovery works in-container (shipped: `nfsdcld` + per-netns rpc_pipefs)

NFSv4 is stateful: after a *server* restart, still-connected clients must
reclaim their state (opens, locks, delegations) during the grace period.
For that, the server needs a persistent store of client identities – the
"client recovery tracking". The kernel provides three mechanisms
(`fs/nfsd/nfs4recover.c`):

1. **cld tracker**: upcalls to a `nfsdcld` daemon over rpc_pipefs; the
   daemon keeps its own (sqlite) store.
2. **UMH helper**: spawns `/sbin/nfsdcltrack` via the usermode helper.
3. **legacy**: filesystem store in a recovery directory.

The app ships mode 1 (`nfsdcld` comes with the `nfs-utils` package the
image already installs, including its sqlite runtime; the daemon needs no
capability grants – it prunes its own capability set at startup). All of
the following was verified in privileged containers against the real host
kernel (kernel v6.18 sources checked for the mechanisms):

- **The upcall pipe lives in the per-netns rpc_pipefs**: the kernel creates
  `<rpc_pipefs>/nfsd/cld` inside the rpc_pipefs superblock registered for
  the server's network namespace (`rpc_get_sb_net(net)`); the `nfsd/`
  subdirectory is pre-created by the kernel when rpc_pipefs mounts. The
  container must therefore mount one itself (`mount -t rpc_pipefs sunrpc
  <dir>`) – `sunrpc` is built-in wherever the NFS *client* is
  (`CONFIG_NFS_FS=y`), i.e. on every HAOS board. Mounting it into the app
  (cont-init) is what makes the whole tracker work in a container.
- **Ordering**: `nfsd4_cld_tracking_init` waits only ~1 s (10 × 100 ms,
  `cld_running` = the pipe has readers/writers) for the daemon to hold the
  pipe open. The s6-rc dependency (`nfsd` oneshot depends on the `cld`
  longrun) keeps the daemon ahead of `rpc.nfsd`; the daemon itself is
  race-tolerant (inotify watch on the pipefs dir – it opens the pipe as
  soon as it appears), so even a slightly late daemon start is fine.
- **Fallback is silent degradation**: if the daemon/pipefs is missing, the
  tracker init times out (`-ETIMEDOUT`) and the dispatcher falls back to
  the legacy trackers, which refuse non-init network namespaces (`net !=
  init_net → -EINVAL`) – the known "Unable to initialize client recovery
  tracking! (-2)" host-log line. The kernel log carries the authoritative
  tracker messages ("NFSD: Using nfsdcld client tracking operations." /
  "no clients to reclaim, skipping NFSv4 grace period") – visible in the
  *host* journal / `dmesg`, NOT in `ha apps logs`.
- **Storage**: `-s <dir>/main.sqlite` (per-epoch record tables
  `rec-<epoch-hex>` plus a `grace` current/recovery epoch table; unclaimed
  records only survive while their epoch is current or the recovery epoch).
  `-p` selects the pipefs root. nfsdcld 2.6.x answers GetVersion with
  upcall protocol version 2.
- **End-to-end verified** (fresh netns + persistent sqlite volume, client
  holding an open fd + exclusive flock across the server recreation): the
  reloaded record makes the kernel run a grace period instead of skipping
  ("starting 300-second grace period"), the client's state manager renews →
  detects the reboot → reclaims (`nfs4_schedule_lease_recovery` traces), a
  held exclusive flock **survives the restart** (contested by a second
  client afterwards: still blocked), and the grace **ends early** once the
  reclaiming client is back (the daemon's GraceDone downcall arrives well
  before the configured grace is up). Fresh boots with no records log
  "no clients to reclaim, skipping NFSv4 grace period" – the kernel's own
  fast path, now reachable because `track_reclaim_completes` is set by the
  cld tracker init (`nfs4_cld_state_init`).
- **Residual unknown**: the exact kernel path that ends the grace early for
  NFSv4.0 reclaimers. The "all clients done reclaiming, ending NFSv4 grace
  period" printk only fires via `inc_reclaim_complete` (the RECLAIM_COMPLETE
  op – the Linux client sends it only for NFSv4.1, confirmed in
  `fs/nfs/nfs4proc.c`'s `nfs40_reboot_recovery_ops`), and the laundromat
  cannot fire before the configured grace on its own schedule – yet the
  observed GraceDone always followed the reclaim promptly. Most plausible:
  reclaim events (`somebody_reclaimed = true` in the reclaim-lock path)
  plus the immediate laundromat kicks (`mod_delayed_work(..., 0)` sites)
  ending the grace once nobody is still reclaiming (`clients_still_reclaiming`).
  Only re-verify if this behavior ever looks wrong.

App wiring: cont-init mounts rpc_pipefs (non-fatal on failure – degraded
mode = the old short-grace behavior) and creates `/data/nfsdcld`; the s6-rc
`cld` longrun execs `nfsdcld -F -p /var/lib/nfs/rpc_pipefs -s
/data/nfsdcld`; the `nfsd` oneshot depends on it. AppArmor: the rpc_pipefs
mount rule plus an `nfsdcld` sub-profile (`deny network,` – the daemon
makes no sockets; it prunes its own capability set at startup and needs a
`capability setpcap` rule for that, see the AppArmor gotchas below).

Facts for mode 3, should it ever matter: the default recovery dir is
hardcoded as `/var/lib/nfs/v4recovery` (`user_recovery_dirname`); it can be
relocated at runtime via the `/proc/fs/nfsd/nfsv4recoverydir` control file
(must be set before the server starts). The app does *not* create that dir:
for the containerized server it would be inert.

## `echo`/`printf` cannot write to `/proc/fs/nfsd/*` (`EINVAL`)

The app base image's bash (5.3.9) implements the output of its `echo` and
`printf` builtins as a single `writev(2)` call, with the text and the
trailing newline as separate iovecs. The kernel's nfsd control files
(`fs/nfsd/nfsctl.c`, `transaction_ops`) only implement the old-style
single-buffer `.write` and no `.write_iter`, and `writev(2)` against such
files fails with `EINVAL` on modern kernels.

Consequences:

- Every `echo`/`printf` redirection into `/proc/fs/nfsd/*` fails with a
  misleading `write error: Invalid argument` – the error is about the syscall
  shape, not the written content (e.g. referencing non-available NFS
  versions is irrelevant here).
- Single-`write(2)` callers succeed: busybox `echo`, `cat`, and `rpc.nfsd`'s
  own writes (which is why `rpc.nfsd` can configure the version set fine).

Workaround, if a direct write to such a kernel file is ever needed: stage the
string in a regular file (e.g. on tmpfs) and `cat` it into the target.

## `rpc.nfsd` is not a daemon

`rpc.nfsd` only configures the NFS server inside the kernel (version set,
sockets, lease/grace time, kernel threads) and then exits – upstream runs it
as a `Type=oneshot` service. That's why the app runs it as an s6-rc `oneshot`
(`up`/`down` scripts in `/etc/s6-overlay/scripts/`): a `longrun` would
restart-loop forever because the process exits immediately, and readiness
polling (`s6-notifyoncheck`) cannot work for a process that is gone.

Consequences for the NFS version set:

- `rpc.nfsd` writes its default version set (NFSv3 and NFSv4) to the kernel
  unless told otherwise – `--no-nfs-version 3` is what keeps this app's
  setup NFSv4-only. The outcome is logged and verified in
  `rootfs/etc/s6-overlay/scripts/nfsd-start`.
- `-N`/`-V` only accept 3 and 4: passing `--no-nfs-version 2` exits with
  `2: Unsupported version` (NFSv2 server support is not compiled into
  current kernels anyway, `CONFIG_NFSD_V2` defaults to off).

## The NFS version set is fixed while the server runs

Once an NFS server instance exists in the kernel (i.e. `rpc.nfsd` started
it), writes to `/proc/fs/nfsd/versions` fail with `EBUSY`, and further
`rpc.nfsd` invocations only adjust the thread count anymore (version/socket
configuration is skipped). Stop the threads with `rpc.nfsd 0` first to
reconfigure.

Within a running container the version set lives in the kernel's network
namespace: it survives s6 service restarts and is only reset to the kernel
defaults (everything compiled-in: `+3 +4 +4.1 +4.2`) when the container –
and with it the network namespace – is recreated.

## Shell: failed redirections bypass the command's `2>/dev/null`

A failed redirection is diagnosed **by the shell itself, before the
command's own redirections are in effect** – `echo x > /some/ro/path
2>/dev/null` still prints `sh: can't create /some/ro/path: …`. To suppress
(or capture) the shell's diagnostic, run the attempt in a subshell:
`out=$( (echo x > /some/ro/path) 2>&1 )` captures message *and* exit code
(used by the `test:live` client script for the grace-period retry and the
read-only assertions).

## AppArmor mediation gotchas (device-verified 2026-10, HAOS 18.3 / OS Agent 1.14 / AppArmor 3.1.7)

- **Capabilities are mediated**: an AppArmor profile without explicit
  `capability …` rules denies all capabilities it is asked about at the LSM
  hook – including the `capable(CAP_SYS_ADMIN)` check inside the mount(2)
  syscall path, even when the `mount …` rule itself grants the mount.
  Docker's default profile carries a blanket `capability,`, so plain Docker
  containers never hit this. The app profile grants `sys_admin` (nfsd mount,
  per-share bind mounts); the container's CapEff (`00000000a82525fb` on the
  device, before `kernel_modules` was dropped) already contained it via
  `privileged: [SYS_ADMIN]`.
  Sub-profile subtlety (device-verified via nfsdcld): capabilities a binary
  needs *for its own self-management* also need rules — `prctl
  (PR_CAPBSET_DROP)` and `capset(2)` require `CAP_SETPCAP`, so the
  `nfsdcld` sub-profile carries `capability setpcap,` (the daemon prunes its
  whole bounding set at startup; without the rule it exits in a restart
  loop: "Unable to prune capability 0 from bounding set: Operation not
  permitted"). The lab cannot catch such issues — it has no AppArmor
  enforcement.
- **Errno forensics replace missing denial logs**: HAOS's kernel produces *no*
  AppArmor audit messages in the host journal (`ha host logs` carries kernel
  lines, but nothing apparmor/DENIED – no usable audit plumbing), so
  complain-mode iteration is impossible and enforcement bugs must be
  diagnosed from boot progress. Useful signals:
  - busybox `mount` prints `mounting SRC on DST failed: Permission denied`
    for **EACCES** (`%m`; observed for a *mount-rule* denial) and
    `permission denied (are you root?)` for **EPERM** (dedicated abort path;
    observed for a *capability* denial).
  - In-container ground truth works and is file-rule-accessible:
    `cat /proc/self/attr/current` (profile + mode) and
    `grep CapEff /proc/self/status`.
- **Mount rule grammar** (parser `apparmor.d.pod`): the mount-flags
  conditional is `options=` (there is no `flags=`); `fstype=` matching only
  applies to *new* mounts – not bind/remount – so `mount --bind` rules are
  conditioned on `options=(bind)` instead. Mount sources are matched as
  passed: busybox passes the device string `nfsd` (not a path). Reference
  rules: `mount fstype=(nfsd) nfsd -> /proc/fs/nfsd/,`,
  `mount options=(bind) /{share,media}{,/**} -> /data/pseudo_root{,/**},`,
  `umount /data/pseudo_root{,/**},`.
- **Iteration mechanics**: the supervisor re-installs (and reloads) the
  profile on `ha apps update`, but `App.rebuild()` does **not** call
  `install_apparmor()` – every profile change needs a `config.yaml` version
  bump so the deploy task takes the update path.
- **Supervisor profile mechanics**: the profile is installed from the app
  folder's `apparmor.txt` on install/update and **renamed to the installed
  slug** (`local_nfs` while testing, `<hash>_<slug>` when installed from a
  repository) – the declared profile name is otherwise arbitrary.
  Requirements: exactly one top-level (non-indented) `profile` declaration
  (the supervisor's profile-name regex rejects more than one), nested
  sub-profiles must be indented so `^profile` doesn't match them. Sources:
  supervisor `utils/apparmor.py`, `apps/app.py`.
- **The kernel's mount-time module autoload makes app-level modprobe
  unnecessary** (device-verified by rebooting with the module unloaded):
  `mount -t nfsd …` makes the kernel `request_module("fs-nfsd")`, which runs
  in kernel context (`call_usermodehelper`) – outside the container's
  AppArmor label and its capability set. Consequently the profile needs no
  `sys_module` capability, no `modprobe` exec rule and no `/lib/modules`
  access, and the app config does not need `kernel_modules: true` (which
  only mapped `/lib/modules` read-only and granted `SYS_MODULE` – both inert
  under the denying profile). Verified on HAOS 18.3 / kernel 6.18.52-haos
  (odroid-m1, CONFIG_NFSD=m): fresh boot with module unloaded → mount
  succeeds, NFS serves, client roundtrip passes.
  rules has networking *entirely unmediated* (everything allowed) – "no
  rules" is not "no networking". Adding any network rule (allow or deny)
  enables mediation, and everything not matched by an allow rule is then
  denied. Device-verified allowlist (parser 5.0.2 does not support
  domain/type tuples – write individual rules):
  `network inet stream/dgram` + `network inet6 stream/dgram` (bashio
  supervisor-API HTTP, DNS, the HEALTHCHECK `/dev/tcp` probe) and
  `network netlink raw` (busybox `ip`'s rtnetlink address detection – easy
  to miss); `deny network,` denies a class outright (used for rpc.nfsd,
  which configures the kernel via procfs and creates no sockets).
