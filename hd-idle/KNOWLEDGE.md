# Development knowledge

App-specific facts only — repository-wide knowledge lives in the repository-root `KNOWLEDGE.md`, runtime procedures in
`.agents/skills/hd-idle-runtime`, open work items in `TODO.md`.

## CLI-only configuration

hd-idle's `main.go` (v1.22) parses `os.Args` and nothing else; the only environment variable it reads is `START_HD_IDLE`
(exits when set to `false`). `/etc/default/hd-idle` and `HD_IDLE_OPTS` are distro-packaging conventions (systemd
`EnvironmentFile=` + shell word-splitting into argv; the Alpine package does the same via its OpenRC `conf.d`). Sources:
[main.go](https://github.com/adelolmo/hd-idle/blob/v1.22/main.go),
[debian/hd-idle.service](https://github.com/adelolmo/hd-idle/blob/v1.22/debian/hd-idle.service), [v3.24
APKBUILD](https://gitlab.alpinelinux.org/alpine/aports/-/blob/3.24-stable/community/hd-idle/APKBUILD). Alpine v3.24
ships `hd-idle 1.22-r8` (`/usr/sbin/hd-idle`, no runtime deps; v1.22 is a GitHub tag without a release; pkgrel bumps so
far are toolchain rebuilds with an unchanged CLI).

## bashio option parsing (list-of-object options)

The bashio option-consumption mechanics (array-option line shapes, the no-trailing-newline last-element hazard, the
`// empty` string-only rule) are repository-wide facts: repository-root `KNOWLEDGE.md` §"bashio option consumption".
hd-idle's reliance: hd-idle-genargs reads the `disks` option line by line (`bashio::jq "${entry}" '.field'`) — a shape
change would break every entry (a lab boot with configured drives catches it), and the per-drive `disable_drive_pm`
override is a `list(yes|no)?` dropdown, not a `bool?`, so "empty" visibly means "follow the global setting"
(`config.yaml`).

## hd-idle CLI semantics relied upon by config.sh

Verified against the v1.22 source (`main.go`, `hdidle.go`):

- Arguments before the first `-a` set the global defaults; each `-a` seeds a per-device config from the defaults parsed
  so far; `-i`/`-c`/`-p` after a `-a` override that device — the generator emits defaults first, then entries.
- First-match-wins: `deviceConfig()` returns the first entry matching the `/proc/diskstats` name. The global idle is
  pinned to `0` (unlisted drives are never touched — device access is per listed drive only); an explicit `-i` follows
  EVERY `-a` (per-drive or default idle), so the passthrough path for detached drives inherits the right idle without a
  watcher restart.
- `-a` accepts a bare kernel name, a `/dev` node (`filepath.Base`), or a `/dev/disk/by-*` symlink (readlink + basename +
  trailing-digit strip — partition links resolve to their disk). `-s 0` resolves once at startup; `-s 1` re-resolves at
  runtime only while the entry is still unresolved (`resolveSymlinks()` skips entries with a populated `Name`) — a
  re-attach under a different kernel name stays stale until an app restart. config.sh therefore resolves by-id paths
  itself and passes `-s 1` only as the fallback for devices unresolvable at startup.
- `-I`, `-d` and `-l` are **global only and position-independent**: the parser assigns them to `Defaults` wherever they
  appear (only `-i`/`-c`/`-p` follow the `-a` context) — both orders are equivalent, do not "reorder" them expecting a
  stricter parse. `-I` fills `Defaults.IgnoreSpinDownDetection`; `DeviceConf` has no such field, and `updateState()`
  reads only the default.
- Poll interval: `min(configured idle)/10` (min 1 s; 60 s with no devices configured); a sleep overrun of >3x the
  interval resets spin state (suspend detection).
- Spindown failure: the device is marked spun down (`LastSpunDownAt=now`) even on error — one error line per idle
  interval, not per poll.
- Events log as `<givenName> spindown|spinup` (with kernel names as given names: `sda spindown`).

## Monitoring scope

`diskstats/snapshot.go` (v1.22) matches `/proc/diskstats` names against `sd[a-z]+$` (disk) and `dm-*$` (dm → holder
disk); anything else (`nvme*`, `mmcblk*`, `loop*`, `ram*`) is never touched — system disks on SD/eMMC/NVMe are out of
hd-idle's reach (third exclusion layer), and NVMe drives cannot be managed at all. The upstream PARTITION matching
(`sd[a-z]+[0-9]+$`) is commented out in v1.22 — partitions are invisible to the daemon; per-partition activity still
wakes the configured disk only because the kernel accumulates partition I/O into the disk's own counters. dm attribution
picks a single holder — upstream reads `/sys/class/block/<dm>/holders/` via `os.ReadDir` (lexicographic order,
deterministic; the app's own attribution is likewise single-holder): a multi-holder dm device (multi-PV LVM) cannot be
managed correctly; the common dm-crypt case (one holder) is exact. Source:
[snapshot.go](https://github.com/adelolmo/hd-idle/blob/v1.22/diskstats/snapshot.go).

## Daemon failure semantics

The daemon is crash-only, with two fatal paths (v1.22 source): a `log.Fatal` when `/proc/diskstats` cannot be opened or
scanned (`diskstats/snapshot.go`), and a `log.Fatal` when the activity log `/data/hd-idle.log` cannot be opened or
written (`logToFile` in `hdidle.go`) — a full or read-only `/data` kills the daemon rather than disabling logging.
s6-supervise restarts the process in both cases, so a *persistent* failure becomes a crash loop that process supervision
cannot distinguish from a healthy app. The Docker HEALTHCHECK is the only container-level signal: `hd-idle-healthcheck`
re-checks both premises (stats file readable; daemon process alive via a `/proc/*/comm` scan) — the file probe covers
diskstats loss, the process probe covers both crash loops. The supervisor relays the resulting health events as bus
events and its app watchdog decides on a restart (root `KNOWLEDGE.md` §"Supervisor: health events and the app
watchdog"). Sources: [snapshot.go](https://github.com/adelolmo/hd-idle/blob/v1.22/diskstats/snapshot.go),
[hdidle.go](https://github.com/adelolmo/hd-idle/blob/v1.22/hdidle.go).

## SG_IO privileges

hd-idle opens disk nodes **O_RDONLY** (`sgio/common.go`, gated by `SG_GET_VERSION_NUM`) and issues `SG_IO` ioctls.
Kernel-side (`drivers/scsi/scsi_ioctl.c` `scsi_cmd_allowed()`, verified against master 2026-10; re-verify against the
device's kernel, 6.18-haos, before relying on it for new work): **START STOP UNIT (0x1B) is "read-safe"** — any process
that can open the node, no capability, no write access; covers hd-idle's `scsi` command type entirely. **ATA
PASS-THROUGH (0x85/0xa1, the `ata` command type) needs `CAP_SYS_RAWIO`** ("root can do any command" branch): the sole
reason for `privileged: [SYS_RAWIO]`, unconditional because Jmicron-quirk USB bridges (supported since 1.21) and all
SATA disks need the `ata` path.

Two independent AppArmor gates, both must be open: (1) the SG_IO ioctl is mediated only via the file's r/w permission
(no per-command mediation until AppArmor 4; mechanism: repository-root `KNOWLEDGE.md` §"AppArmor: mediation and profile
mechanics") — `/dev/sd* rwk,` plus the `file,` blanket covers it; (2) the kernel's `capable(CAP_SYS_RAWIO)` check inside
`scsi_cmd_allowed()` is mediated by AppArmor itself (same root section) — both profiles need `capability sys_rawio,`.
Without (2) every ata-path command failed with EPERM despite the container capability: capable() returned false and
`scsi_cmd_allowed()` fell through to `return open_for_write` (the EPERM source for O_RDONLY fds).

**Why the capability cannot be tightened**: AppArmor capability rules enumerate whole capabilities (they mediate the
kernel's boolean `capable()` check — apparmor.d(5)), so a fraction of `CAP_SYS_RAWIO` is not expressible; per-command
ioctl mediation does not exist upstream; HAOS ships AppArmor 3.1.7. **Both grant sites are needed**: the daemon
sub-profile (ata spindowns) and the top profile (pmfix's smartctl ATA SET FEATURES is the same non-read-safe class;
`hd-idle -t` runs in the top profile, e.g. the lab's `docker exec`). What the capability additionally unlocks in this
container (capabilities(7)): `/proc/kcore` reads (kernel-gated on capable(CAP_SYS_RAWIO), file side allowed by the
`file,` blanket — genuinely reachable for a compromised process; the accepted residual risk of the ata path) and
`ioperm`/`iopl` (x86/amd64). Closed surfaces: `/dev/mem`, `/dev/kmem`, `/dev/port`, `/dev/cpu/*/msr` (outside the
supervisor's device-cgroup allowlist); `mmap_min_addr` (moot: `/proc/sys` mounted read-only); SCSI commands to other
nodes (device cgroup); seccomp could trim further but the supervisor exposes no per-app seccomp customization.

## Device access in this app

Mechanics: repository-root `KNOWLEDGE.md` §"Supervisor: device access" (verified at supervisor ref 2026.10.1 — re-verify
per the version-sensitive-facts rule before relying on them for new work).

- Access is granted **exclusively via device-typed option fields**: `disks[].device` (`device(subsystem=block)`) —
  cgroup rules per configured drive, UI dropdown of stable by-id paths, hotplug re-grant via udev links (no restart
  needed on re-plug), system-disk refusal (exclusion layer 1). Hence every managed drive must be listed; unlisted drives
  are pinned to never spin down instead of being attempted.
- Saving options while a drive is detached fails (device existence is validated at save time); at boot the validation is
  suppressed — a detached drive does not prevent the app from starting (config.sh passes it through for hd-idle's
  runtime resolution).
- Plain Docker (the lab) exposes no `/dev/disk` udev symlink trees (HAOS binds the host `/dev` read-only into app
  containers); the lab hook mirrors them with `-v /dev/disk:/dev/disk:ro` so by-id resolution and inventory behave as on
  a device.

## Security rating ceiling

Formula, branches and sources: repository-root `KNOWLEDGE.md` §"Supervisor: app security rating". This app: 5 + 1
(custom profile) + 2 (no ports, no host network) − 1 (`SYS_RAWIO` is in the high-risk capability list) = **7 installed,
6 in the store listing**. `full_access` is deliberately avoided: rating 1, protection mode off, and cgroup access to
*all* devices including the system disk — which the device-option mechanism refuses precisely.

## hd-idle -t quirks

- The disk argument needs the **full `/dev/` path**: single-shot passes the argument straight to `openDevice` (the
  daemon path prefixes `/dev/`) — bare names fail (`open sda: no such file or directory`); the usage string's `-t sda`
  example is misleading.
- It uses the **global default** command type / power condition only (single-disk mode skips the per-device config
  entirely).

No in-app caller since the diagnostics build was reverted; the lab spindown smoke test drives it via `docker exec`, and
it is useful for manual debugging.

## USB-bridge behaviors

Empirical findings from WD USB bridges (My Book 1110/1230/25EE, Elements 107C, Ext HDD 1021) on test hardware; matrix
entries are per-bridge firmware behavior.

- **`hdparm -C` is not a safe probe** for these drives: it races the spin-down window (NOT READY sense data, ASC/ASCQ 04 01)
  and then **wakes the drive** — CHECK POWER MODE is forwarded to the drive: truthful, but spin-up inducing. Use
  **`smartctl -H -n standby`** (exit code 2, "Device is in STANDBY/SLEEP mode", no media access), with polling retries
  (desktop IO on mounted drives may wake a drive between the STOP command and the probe); that is what the lab hook
  does.
- **Bridges lie about the power state**: the firmware answers SCSI power-condition queries (the sense data behind
  `smartctl -H -n standby`; hd-idle's own state view is equally blind) from its **own** model without consulting the
  drive. A host-invisibly self-woken drive still reports STANDBY/SLEEP to every passive host-side probe, with frozen
  `/proc/diskstats` counters: hd-idle's diskstats-based belief never resets after such a wake — it never re-issues a
  spindown, so a drive can spin for hours while the app reports it as spun down. The only host-side truth is the ramp-up
  latency of a *real* read (an asleep drive takes the motor ramp; bypass the page cache, read far offsets) — intrusive,
  it wakes an asleep drive. Prevention beats detection: the drives' own power management off plus a spindown command
  class the bridge actually honors (§"Drive-PM treatment", `TODO.md`).
- **Drive-PM matrix**: `standby,off` is honored by ALL five bridges (the universally deliverable part); `apm,off` only
  by the My Book 25EE bridge ("APM disabled", reads back as Disabled) — the other four fail with "scsi error aborted
  command" (107C, 1230) resp. "SAT command failed" (1110, 1021), their APM feature page filtered entirely (smartctl:
  "APM feature is: Unavailable"); non-fatal by design, logged once. Treatment settings are volatile (reset on drive
  power cycle): re-applied at boot and on (re)appearance.
- **Redundant STOP commands are not harmless**: a STOP to an already-asleep drive half-started the motor (My Book 1230,
  audibly). Consequences: hd-idle's `-I` re-asserts spindowns to EVERY still-asleep drive once per idle interval
  (source-verified `updateState()`) — on such bridges a wear generator, not production-safe; and each app restart fires
  one spindown wave at ALL drives (fresh state; restarts are rare — real config changes only). Upstream-report items
  (`TODO.md`).
- **Same-kernel-name reconnect gap**: a drive whose bridge power-cycles it while it reconnects under the SAME kernel
  name is invisible to the watcher's `--since` diff and stays untreated until the next app restart (`TODO.md`).

## Drive-PM treatment

`hd-idle-pmfix` disables the drives' own power management (ATA SET FEATURES: APM level off + standby timer off) for
every managed drive whose EFFECTIVE pm-flag is 1 (the global `disable_drive_pm` option as the default, per-drive
`disable_drive_pm` yes/no overrides) at boot and on drive (re)appearance — the watcher re-applies to NEW/CHANGED drives
only (redundant treatment of sleeping drives risks bridge-mediated motor starts, §"USB-bridge behaviors").

The drives file (`/etc/hd-idle.drives`, written by hd-idle-genargs next to the args file) is pmfix's machine-readable
interface and the single source of truth for the effective per-drive decision: one
`<kernel-name> <idle> <command-type> <pm-flag>` line per drive with effective values (exclusions: idle 0, pm-flag 0).
pmfix treats only pm-flag 1 entries; the idle time plays no role — an idle-0 drive is a treatment target all the same
(its firmware timer must not fight the user's "never spin down" config). A missing pm-flag column (a pre-0.1.6 3-column
file — cannot occur in practice) means treat. config.sh and the watcher run pmfix unconditionally (a global-only bashio
gate could not express per-drive overrides); `--since <old-file>` treats only lines NEW or CHANGED relative to it — a
flipped pm-flag counts as changed, so a newly overridden drive is treated exactly once and an unchanged override stays
skipped.

Treatment-success detection (`smart()` in hd-idle-pmfix) requires smartctl exit 0 AND output free of
`failed|unknown|unavailable`: the exit code alone does not certify that ATA SET FEATURES took effect —
feature-page-filtered bridges answer "APM feature is: Unavailable" with exit 0 (the silent-no-op class of §"USB-bridge
behaviors"). The failure-detail grep uses a different word list (`failed|unavailable|aborted|invalid`) — it only picks a
log line for the message. Every treatment call pins `-d sat` (SAT passthrough for every sd\* device — no reliance on
smartctl's per-device type auto-detection) and is capped at `timeout 60` (a wedged bridge or slow motor ramp-up must
neither stall the s6 boot nor wedge a watcher tick).

## hd-idle-watch design

- **The problem**: hd-idle resolves its `-a` entries once at startup and `-s 1` re-resolves only still-unresolved ones,
  while kernel names (`sdX`) are not stable across re-plugs (ports/hubs, enumeration order): a moved drive keeps its
  stale entry — watched under the wrong name or none — until an app restart fixed it.
- **The supervisor cannot help**: its HARDWARE_NEW_DEVICE handling only re-grants cgroup device rules to the running
  container — no callback/notification API, no restart-on-device-change (verified against supervisor 2026.10.1). The fix
  is entirely app-internal.
- **Design**: arg generation lives in the shared helper `/usr/bin/hd-idle-genargs`; `hd-idle-watch` polls every 30 s
  (`HD_IDLE_WATCH_INTERVAL` override, floored at 5 s — the lab sets 5 s; mirrors nfsd-watch's `NFSD_WATCH_INTERVAL`):
  check first (baseline replay), and on a detected change regenerate into candidate files, compare, and install.
  Regenerated args AND drives matching the installed ones = only the baseline state is stale → resync without restart;
  otherwise install the candidates and restart just the hd-idle service (`s6-svc -r /run/service/hd-idle`). The state
  file (`<args-stem>.resolution`, e.g. `/etc/hd-idle.resolution`) is installed last (commit point — it records the shas
  of the two files just installed): a crash before it leaves the recorded shas mismatching the installed files, and the
  next tick re-syncs. Unchanged ticks log nothing; the new command line is logged by the hd-idle run script after each
  restart. Polling instead of udev events: mapping the host's `/run/udev` socket (`with_udev`) into an Alpine-based
  container is version-fragile for zero gain — 30 s worst-case latency is fine for a maintenance action.
- **Quiet mode and the baseline replay**: `--quiet` (the watcher's per-tick mode) suppresses narrative/info output and
  the expected-transient warnings (detached drive, non-sd\* entry) — both surface once per boot from the non-quiet
  cont-init run, and options cannot change mid-run (repository-root `KNOWLEDGE.md` §"Supervisor: option schema quirks");
  errors always log. `--check` (the nfsd-apply pattern, nfs-server commit d78c7ea) replays the **resolution baseline**
  the full generation recorded: the sha256 of each installed file plus the detection facts it was generated from
  (system-disk set; every configured device's resolution outcome — kernel name, `PASSTHRU`, or `IGNORED`), with no
  option reads, no jq, no file writes. Exit 0 = unchanged, 3 = changed (regeneration due), any other nonzero = check
  failure (the watcher keeps the current configuration: args file plus running argv, untouched). Because options are
  immutable mid-run, the recorded facts fully determine a regeneration; installed-file drift (hand edits, corruption,
  interrupted install) is caught by the shas — detection-equivalent to a full regenerate-and-compare. The state file is
  written LAST by the generation (commit point); its name derivation mirrors the drives file (`companion_file`, mirrored
  inline in the watcher run script).
- **Restart effects are benign**: the run script re-reads the args file; hd-idle starts with fresh in-memory stats (idle
  timers restart) and sends no command at startup — a drive in standby is NOT spun up by the restart. Cosmetic: an
  activity-log "running" period spanning the restart is misaccounted.
- **The clean upstream fix** would make the watcher redundant: re-verify already-resolved symlinks each cycle in `-s 1`
  mode and update changed entries (`TODO.md`); remove the watcher when upstream ships the behavior (Alpine package users
  get it via a package version bump + app version bump).
- **The failure class is nearly empty by construction**: options cannot change under a running app (the supervisor
  validates at save time and hands over new options.json only at the app's next start) — all config-content rejections
  fire at boot; device-resolution failures are not failures (passthrough path). The one reachable mid-run failure: two
  configured symlink names of the same physical drive (drives can carry several by-id links, e.g. `ata-*` and `usb-*`
  for one disk) with one detached at boot — the duplicate-entry rejection fires per tick (ERROR lines every 30 s until
  the user fixes the config; spammy but truthful, accepted). Known-good = the args file plus the running daemon's argv,
  both untouched on failure; the persistent source of truth is `options.json` on /data.
