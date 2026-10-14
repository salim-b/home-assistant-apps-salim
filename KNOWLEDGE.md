# Development knowledge (repository-wide)

Non-obvious facts and gotchas that apply to **Home Assistant apps in
general** — supervisor behaviors, AppArmor, the HA base image, testing —
collected here for human developers and agents alike, so they don't have to
be re-learned per app. Root causes and design facts specific to one app live
in its `<app>/KNOWLEDGE.md`; process and commands for agents live in
`AGENTS.md`; end-user documentation in `<app>/DOCS.md`.

Facts about version-sensitive components (supervisor, AppArmor, HAOS
kernels) cite their source (URL + ref) and must be re-verified before
relying on them for new work (see `AGENTS.md`, workflow rules). Supervisor
facts below were verified at ref 2026.10.1 (the pin in `mise.toml`), some
also at 2026.09.3 as noted.

## Supervisor: app security rating

`supervisor/apps/utils.py::rating_security` starts at **5** (1–8 clamp) and
adjusts:

- AppArmor: disabled −1 / custom profile **+1** (not +2 — easy to miscount)
- Ingress +2; *else* no host network **and no published ports** +2; *else*
  supervisor-auth-API access +1
- signed +1 — **unreachable**: `AppModel.signed` is a hardcoded `False`
  stub ("Currently no signing support"; verified in 2026.09.3 and 2026.10.1).
  Images may well be cosign-signed (our CI does keyless signing), but the
  supervisor cannot credit it — treat signing as supply-chain hygiene only.
- High-risk capabilities −1 (a single deduction for the whole branch):
  `BPF`, `CHECKPOINT_RESTORE`, `DAC_READ_SEARCH`, `NET_ADMIN`, `NET_RAW`,
  `PERFMON`, `SYS_ADMIN`, `SYS_MODULE`, `SYS_PTRACE`, `SYS_RAWIO` — or
  `kernel_modules: true`
- `hassio_role` manager/admin −1/−2
- host networks −1 (net) / −2 (pid) / −1 (uts + `SYS_ADMIN`)
- docker-API access or `full_access` → **forced to 1** — and `full_access`
  (with docker API / host PID / host UTS) requires protection mode to be
  disabled by the user, which the `privileged` capability list does not
  (only those keys are gated by protection mode; supervisor
  `docker/app.py`).

Store listing vs. installed app can differ by the AppArmor +1 — expected,
not a device quirk: `AppModel.apparmor` (supervisor `apps/model.py`,
verified 2026.09.3) returns `SECURITY_PROFILE` only when a profile *for this
app is already installed on the host* (`sys_host.apparmor.exists(slug)`
checks the supervisor's AppArmor profile store, which `install_apparmor()`
fills during app install/update). A store-listed app has no profile on the
host yet → `SECURITY_DEFAULT` → the branch contributes 0 → the store shows
one less than the installed rating. It is *not* related to AppArmor support
on the device — hosts without AppArmor support don't show different ratings;
they reject installing such apps outright (`UnsupportedReason.APPARMOR`).

## Supervisor: option schema quirks

- `match(...)` regexes in `config.yaml` schema fields use voluptuous `Match`
  (*search* semantics, not fullmatch) — always anchor with explicit `^…$`.
- The supervisor's schema-element parser breaks on literal `\t`/`\n` inside
  YAML double-quoted scalars (they become real control characters) — express
  whitespace classes as `\\s` instead.
- The options DSL (`supervisor/apps/options.py` `RE_SCHEMA_ELEMENT`) has
  **no uniqueness construct** — list-of-objects options are validated entry
  by entry, cross-entry constraints cannot be expressed (the supervisor
  itself uses `vol.Unique()`, but only in its *own* config schemas, e.g. the
  `machine` list). Cross-entry guards therefore belong in the app's runtime
  scripts (defense in depth), backed by `match()` regexes on the fields.
- Options are validated **at save time** (schema incl. device-path
  existence) and delivered to the running app only at its next (re)start —
  option values cannot change under a running app
  (`supervisor/api/apps.py` options endpoint → `app.save_persist()`).

## Supervisor: device access

- Every app container gets the **host `/dev` bind-mounted read-only**
  (`supervisor/docker/const.py` `MOUNT_DEV`, with
  `read_only_non_recursive=True`), so the udev symlink trees
  (`/dev/disk/by-id`, `by-uuid`, `by-partlabel`, …) are visible to the app
  on a real device. Plain Docker containers get a tmpfs `/dev` with bare
  device nodes instead — no `/dev/disk` (the lab mirrors it, see below).
  What actually gates access are Docker `DeviceCgroupRules`, computed per
  app from the sources below.
- **Device-typed option fields** (`device` schema type, optionally
  `device(subsystem=<udev-subsystem>` — values from `hardware/const.py`
  `UdevSubsystem`, e.g. `block`, `usb`, `tty`) grant the cgroup rules
  (`c`/`b <major>:<minor> rwm`). `AppOptions._collect_device_paths`
  **recurses into list-of-objects schemas**, so `disks[].device` fields of
  a list option grant access per entry. The UI renders them as a dropdown
  of `(device.by_id or device.path)` values; the subsystem filter is by udev
  subsystem only (for `block` this still includes partitions and loops).
- **Hotplug**: `docker/app.py::_hardware_events` listens for
  HARDWARE_NEW_DEVICE and re-grants the cgroup rule when a new device
  matches one of the configured paths against `device.path`, `device.sysfs`
  or **`device.links`** (the udev symlinks — hence by-id paths match after
  re-plugging even when the kernel letter changed). No app restart needed.
- **System-disk rail**: `hardware/policy.py::allowed_for_access` refuses
  devices where `sys_hardware.disk.is_used_by_system(device)` — at container
  start and in the hotplug listener alike. Devices the system uses cannot be
  granted to an app, period.
- Validation timing: the `device` type validates existence **at options save
  time** (`write_options` → `get_by_path`) — saving a config while the
  device is detached fails with a clear message. At app **startup** the
  validation result is suppressed (`App.devices` does
  `with suppress(vol.Invalid)`); a detached device at boot does not prevent
  the app from starting.

## AppArmor: mediation gotchas and profile mechanics

Device-verified 2026-10 on HAOS 18.3 / OS Agent 1.14 / AppArmor 3.1.7.

- **Capabilities are mediated**: a profile without explicit
  `capability …` rules denies all capabilities it is asked about at the LSM
  hook — including the `capable(CAP_SYS_ADMIN)` check inside the mount(2)
  syscall path, even when the `mount …` rule itself grants the mount.
  Docker's default profile carries a blanket `capability,`, so plain Docker
  containers never hit this. List every capability the binaries need.
  Sub-profile subtlety: capabilities a binary needs *for its own
  self-management* also need rules — `prctl(PR_CAPBSET_DROP)` and
  `capset(2)` require `CAP_SETPCAP` (found via nfsdcld, which prunes its
  whole bounding set at startup: without the rule it exits in a restart
  loop, "Unable to prune capability 0 from bounding set: Operation not
  permitted"). The lab cannot catch such issues — it has no AppArmor
  enforcement.
- **Errno forensics replace missing denial logs**: HAOS produces *no*
  AppArmor audit messages in the host journal (`ha host logs` carries kernel
  lines but nothing apparmor/DENIED — no usable audit plumbing), so
  complain-mode iteration is impossible; enforcement bugs must be diagnosed
  from boot progress. Useful signals:
  - busybox `mount` prints `mounting SRC on DST failed: Permission denied`
    for **EACCES** (`%m`; observed for a *mount-rule* denial) and
    `permission denied (are you root?)` for **EPERM** (dedicated abort path;
    observed for a *capability* denial).
  - In-container ground truth is file-rule-accessible:
    `cat /proc/self/attr/current` (profile + mode) and
    `grep CapEff /proc/self/status`.
- **Mount rule grammar** (parser `apparmor.d.pod`): the mount-flags
  conditional is `options=` (there is no `flags=`); `fstype=` matching only
  applies to *new* mounts — not bind/remount — so `mount --bind` rules are
  conditioned on `options=(bind)` instead. Mount sources are matched as
  passed: busybox passes the device string for pseudo-filesystems (e.g.
  `nfsd`, `sunrpc`, not a path).
- **Ioctls**: AppArmor 3.x mediates ioctls only via the file's r/w
  permission (no per-command mediation until AppArmor 4) — e.g. `SG_IO` on
  disk nodes is covered by `/dev/sd* rwk`-style file rules, and no
  capability rules are needed for the ioctl itself.
- **Network mediation is opt-in per class**: a profile without any
  `network` rules has networking *entirely unmediated* (everything allowed)
  — "no rules" is not "no networking". Adding any network rule (allow or
  deny) enables mediation, and everything not matched by an allow rule is
  then denied; `deny network,` denies a class outright. The parser (5.0.2)
  does not support domain/type tuples — write individual rules
  (`network inet stream`, `network inet dgram`, `network inet6 …`,
  `network netlink raw`, …).
- **File-rule tightening is impractical**: without audit logs there is no
  way to iterate file rules safely, so a `file,` blanket is the upstream HA
  convention (docs template, dnsmasq, this repo's apps). The profile's
  confinement value sits in the non-file classes (network, capability,
  mount), which Docker's default profile would otherwise grant broadly.
- **Supervisor profile mechanics**: the profile is installed from the app
  folder's `apparmor.txt` on install/update and **renamed to the installed
  slug** (`local_<slug>` for repo-folder installs, `<hash>_<slug>` when
  installed from a repository) — the declared profile name is otherwise
  arbitrary. Requirements: exactly one top-level (non-indented) `profile`
  declaration (the supervisor's profile-name regex rejects more than one);
  nested sub-profiles must be indented so `^profile` doesn't match them.
  Sources: supervisor `utils/apparmor.py`, `apps/app.py`.
- **Profile changes need a `config.yaml` version bump**: the supervisor
  re-installs (and reloads) profiles on app *update*, but `App.rebuild()`
  does **not** call `install_apparmor()` — a no-bump change of
  `apparmor.txt` is silently not applied on the device.
- **Kernel module autoload via mount is kernel-context, outside the label**:
  mounting a filesystem type whose module is not loaded makes the kernel
  `request_module(...)` in kernel context (`call_usermodehelper`) — outside
  the container's AppArmor label and capability set. Consequently mounting
  e.g. `nfsd` needs no app-level modprobe, no `sys_module` capability, no
  `/lib/modules` access and no `kernel_modules: true` (verified on HAOS
  18.3 / kernel 6.18.52-haos by rebooting with the module unloaded; the
  `kernel_modules` option only maps `/lib/modules` read-only and grants
  `SYS_MODULE` — both inert under a denying profile).

## HA base image: shell gotchas

- **`echo`/`printf` emit a single `writev(2)`**: the base image's bash
  (5.3.9) implements the output of its `echo` and `printf` builtins as one
  `writev(2)` call, with the text and the trailing newline as separate
  iovecs. Kernel files that only implement the old-style single-buffer
  `.write` and no `.write_iter` (many procfs/sysfs transaction files, e.g.
  `/proc/fs/nfsd/*`) reject `writev(2)` with `EINVAL` on modern kernels —
  producing a misleading `write error: Invalid argument` that is about the
  syscall *shape*, not the written content. Callers that do a single
  `write(2)` (busybox `echo`, `cat`, many C daemons' own writes) succeed.
  Workaround when a direct write is unavoidable: stage the string in a
  regular file (e.g. on tmpfs) and `cat` it into the target. (Which files
  this bites in a given app: see the app's `KNOWLEDGE.md`.)
- **Failed redirections bypass the command's `2>/dev/null`**: a failed
  redirection is diagnosed by the shell itself, *before* the command's own
  redirections are in effect — `echo x > /some/ro/path 2>/dev/null` still
  prints `sh: can't create /some/ro/path: …`. To suppress (or capture) the
  shell's diagnostic, run the attempt in a subshell:
  `out=$( (echo x > /some/ro/path) 2>&1 )` captures message *and* exit
  code.

## Testing: hardware-behavior checks in the lab

The lab boots app containers `--privileged` **on the dev machine**, so
host-side hardware state interacts with tests:

- **Host-side interference sweep**: OS-level power-management mechanisms can
  skew hardware tests (for disk spindown: udisks2 stored drive settings —
  re-applied on every hotplug; `/etc/hdparm.conf` directives; TLP `DISK_*`;
  smartd; powertop auto-tune; the per-device runtime-PM `power/control`
  state) — and the inverse, desktop IO on mounted devices waking them.
  Mainstream distros ship none of these active by default; they are
  user-configured. App hooks doing hardware tests should run a read-only
  preflight sweep and warn (see `hd-idle`'s lab hook for the pattern).
- **Assert event-based, never "stays in state for N minutes"**: hardware
  state can legitimately change (a drive woken by unrelated IO is correct
  system behavior) — assert the event/transition (log lines, state probes
  right after a triggered command) rather than persistence of a state.
- **Probe tools can themselves disturb the state**: verify your probe is
  side-effect-free (e.g. `hdparm -C` both races spin-down windows and can
  *wake* USB-attached drives; `smartctl -n standby` is designed not to).
  Device/bridge-specific findings live in the apps' `KNOWLEDGE.md`.
- **Plain Docker vs. HAOS `/dev`**: see the device-access section — when an
  app's behavior depends on the udev symlink trees, the lab hook must mirror
  the supervisor's read-only host-`/dev` bind (e.g. `-v /dev/disk:/dev/disk:ro`).
