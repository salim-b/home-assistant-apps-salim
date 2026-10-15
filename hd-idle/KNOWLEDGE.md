# Development knowledge

Non-obvious facts and gotchas learned while developing this app, collected here so they don't have to be re-learned the
hard way. App-specific facts only — repository-wide knowledge (supervisor rating formula, schema quirks, device access,
AppArmor mechanics, base-image shell gotchas, lab testing) lives in the repository-root `KNOWLEDGE.md`.

## hd-idle configuration is command-line-only

`main.go` (v1.22) parses `os.Args` and nothing else. The `/etc/default/hd-idle` file and the `HD_IDLE_OPTS` variable are
distro-packaging conventions: the systemd unit declares `EnvironmentFile=/etc/default/hd-idle` and
`ExecStart=/usr/sbin/hd-idle $HD_IDLE_OPTS` – the shell word-splits the variable into argv. The Alpine package does the
same via its OpenRC `conf.d` file. The only environment variable the binary itself reads is `START_HD_IDLE` (exits
immediately when set to `false`). Sources:
[debian/hd-idle.service](https://github.com/adelolmo/hd-idle/blob/v1.22/debian/hd-idle.service),
[main.go](https://github.com/adelolmo/hd-idle/blob/v1.22/main.go), [v3.24
APKBUILD](https://gitlab.alpinelinux.org/alpine/aports/-/blob/3.24-stable/community/hd-idle/APKBUILD).

Alpine v3.24 ships `hd-idle 1.22-r7` (community repo; v1.22 is a GitHub tag *without* a release). The package installs
`/usr/sbin/hd-idle`, has no runtime dependencies, and is built from the same code as the v1.22 tag (`main.go` is
byte-identical to it as of 2026-10).

## hd-idle CLI semantics relied upon by config.sh

Verified against the v1.22 source (`main.go`, `hdidle.go`):

- Arguments before the first `-a` set the global defaults; each `-a` seeds a per-device config **from the defaults
  parsed so far**, and `-i`/`-c`/`-p` after a `-a` (before the next one) override that device's values. Our generator
  therefore always emits defaults first, then entries.
- Unconfigured devices are governed by the global defaults: opt-in mode pins the global idle to `0`, and the system disk
  gets an explicit `-a <disk> -i 0` entry (first-match-wins: `deviceConfig()` returns the first device entry whose name
  matches the `/proc/diskstats` name).
- `-a` accepts a bare kernel name (`sda` – returned as-is), a `/dev` node (`filepath.Base`), or a `/dev/disk/by-*`
  symlink (readlink + basename + trailing-digit strip, i.e. partition links resolve to their disk). Resolution happens
  once at startup with `-s 0`; `-s 1` re-resolves at runtime **only while the entry is still unresolved** – a device
  that re-attaches with a different kernel name after being resolved stays stale until an app restart. That is why
  config.sh resolves by-id paths itself (kernel names are stable within a boot) and passes `-s 1` only as the fallback
  for devices unresolvable at startup.
- `-I` (ignore spin-down detection) is **global only**: parsed as a valueless flag into
  `Defaults.IgnoreSpinDownDetection`; `DeviceConf` has no such field and `updateState()` reads only the default.
- `-d` (debug) and `-l` (logfile) are **global only and position-independent**, like `-I`: the parser assigns them to
  `Defaults` no matter where they appear - only `-i`/`-c`/`-p` follow the `-a` context. The generator therefore appends
  them after the `-a` entries; both orders are equivalent, do not "reorder" them expecting a stricter parse.
- The poll interval is `min(configured idle)/10` (min 1 s; 60 s when no devices are configured); a sleep overrun of >3x
  the interval resets spin state (suspend detection).
- Spindown failures do not loop per poll cycle: the device is marked spun down with `LastSpunDownAt=now` even on error,
  so an unspindownable disk produces one error line per idle interval, not per poll.
- Events are logged as `<givenName> spindown|spinup` to stdout; with kernel names as given names the app log reads
  `sda spindown`.

## hd-idle's monitoring scope

`diskstats/snapshot.go` matches `/proc/diskstats` names against `sd[a-z]+$` (disk), `sd[a-z]+[0-9]+$` (partition →
attributed to parent disk) and `dm-*$` (device-mapper → attributed to its holder disk). **Anything else is never
touched**: `nvme*`, `mmcblk*`, `loop*`, `ram*`. Consequences: system disks on SD/eMMC/NVMe are out of hd-idle's reach
(third exclusion layer), and the app cannot manage NVMe drives at all. Partition/dm attribution also makes per-partition
activity wake the configured disk.

## SG_IO privileges: what the kernel actually requires

hd-idle opens disk nodes **O_RDONLY** (`sgio/common.go openDevice`, gated by `SG_GET_VERSION_NUM`) and issues `SG_IO`
ioctls. Kernel-side (`drivers/scsi/scsi_ioctl.c`, `scsi_cmd_allowed()` – verified against master 2026-10; re-verify
against the device's kernel (6.18-haos) before relying on it for new work):

- **START STOP UNIT (0x1B) is in the "read-safe" list**: allowed for any process that can open the node – no capability,
  no write access needed. This covers hd-idle's `scsi` command type entirely.
- **ATA PASS-THROUGH (0x85/0xa1, the `ata` command type) is in neither list** → requires `CAP_SYS_RAWIO` (the kernel's
  "root can do any command" branch). That is the sole reason for the app's `privileged: [SYS_RAWIO]`. It is
  unconditional in `config.yaml` because some USB bridges (Jmicron quirk, supported since 1.21) and all SATA disks need
  the `ata` path.

Consequence for the profile: AppArmor 3.x mediates ioctls only via the file's r/w permission (no per-command mediation
until AppArmor 4 — the mechanism is repository-wide, see the repository-root `KNOWLEDGE.md`), so `/dev/sd* rwk,` (plus
the `file,` blanket) covers the ioctl path; no capability rules are needed for it.

## Device access in this app (mechanics: repository-root `KNOWLEDGE.md`)

Supervisor facts verified at ref 2026.10.1 — re-verify per the version-sensitive-facts rule before relying on them for
new work.

- The app grants device access **exclusively via device-typed option fields**: `disks[].device`
  (`device(subsystem=block)`) — cgroup rules per configured drive, UI dropdown of stable by-id paths, hotplug re-grant
  via udev links (no restart needed on re-plug), and the system-disk refusal as exclusion layer 1. This is why opt-out
  mode can only work for listed drives and why every managed drive must be listed.
- Validation timing matters for the UX: saving options while a drive is detached fails (device existence is validated at
  save time); at boot the validation is suppressed, so a detached drive does not prevent the app from starting
  (config.sh passes it through for hd-idle's runtime resolution, see the watcher section below).
- Plain Docker (the lab) exposes no `/dev/disk` udev symlink trees (HAOS binds the host `/dev` read-only into app
  containers) — the lab hook mirrors it with `-v /dev/disk:/dev/disk:ro` so config.sh's by-id resolution and inventory
  behave as on a device.

## Security rating — this app's ceiling

For the rating *formula* (every branch, sources, the store-vs-installed delta) see the repository-root `KNOWLEDGE.md`.

For this app (0.1.0): 5 + 1 (custom profile) + 2 (no ports, no host network) − 1 (`SYS_RAWIO` is in the high-risk
capability list) = **7 installed, 6 in the store listing**. `full_access` would force the rating to 1 and disable
protection mode — deliberately avoided: it would grant cgroup access to *all* devices including the system disk, which
the device-option mechanism refuses precisely.

## hd-idle -t (single-shot spindown) quirks

- The disk argument needs the **full `/dev/` path**: single-shot mode, unlike the daemon path (which does
  `fmt.Sprintf("/dev/%s", name)`), passes the argument straight to `openDevice` - bare kernel names fail with
  `open sda: no such file or directory`. The usage string's `-t sda` example is misleading. Verified against v1.22
  (`main.go` singleDiskMode branch).
- The command uses the **global default** command type / power condition only (single-disk mode skips the per-device
  config entirely).

## Verifying drive power states from the lab (USB bridges)

`hdparm -C` is **not a safe probe** for these drives: empirically (WD My Book 1230 / Elements 25A3 USB bridges on this
machine) it races the spin-down window (`SG_IO: bad/missing sense data` with sense key 70 00 02, ASC/ASCQ 04 01 = NOT
READY / "in process of becoming ready") and then **actually wakes the drive** (STOP → `smartctl -n standby` says SLEEP →
one `hdparm -C` → smartctl says active). Use **`smartctl -H -n standby`** instead (exit code 2 + "Device is in
STANDBY/SLEEP mode" without any media access) - that is what the lab hook does, with polling retries (desktop IO on
mounted drives may wake a drive between the STOP command and the probe).

## Automatic drive re-resolution (hd-idle-watch)

- **The problem**: hd-idle resolves its `-a` device entries **once** at startup; `-s 1` re-resolves *only entries that
  are still unresolved* (`resolveSymlinks()` skips entries whose `Name` is already populated - verified in v1.22).
  Kernel names (`sdX`) are not stable across re-plugs (different ports/hubs, enumeration order), so a moved drive would
  keep its stale entry: hd-idle watches (and spins down) the wrong name or none, until an app restart fixed it.
- **The supervisor cannot help**: its HARDWARE_NEW_DEVICE handling only re-grants cgroup device rules to the *running*
  container - there is no callback/notification API to apps and no restart-on-device-change mechanism (verified against
  supervisor 2026.10.1). The fix is entirely app-internal; no HAOS interaction is involved.
- **Design**: the arg generation lives in a shared helper (`/usr/bin/hd-idle-genargs`, used by cont-init config.sh and
  the watcher). The `hd-idle-watch` longrun polls every 30 s: regenerate the command line with `hd-idle-genargs --quiet`
  into a candidate file, `cmp` it against `/etc/hd-idle.args`, and only on an actual difference install the new file and
  restart just the hd-idle service (`s6-svc -r /run/service/hd-idle`). Unrelated churn therefore never triggers a
  restart, and `--quiet` makes unchanged 30-s ticks produce **no log output at all** (warnings/errors still surface; the
  new command line is logged by the hd-idle run script after each restart). Polling (not udev events) because mapping
  the host's `/run/udev` socket (`with_udev`) into an Alpine-based container for event-driven monitoring is
  version-fragile for zero gain - 30 s worst-case latency is fine for a maintenance action.
- **hd-idle restart effects are benign**: the run script re-reads the args file; hd-idle starts with fresh in-memory
  stats (idle timers restart) and no command is sent to any disk at startup - a drive in standby is NOT spun up by the
  restart. Minor cosmetic cost: an activity-log "running" period spanning the restart is misaccounted (hd-idle cannot
  know it was restarted).
- **The clean upstream fix** would make the watcher redundant: re-verify already-resolved symlinks each cycle in `-s 1`
  mode and update changed entries (see TODO.md). Until then the watcher is the app-side workaround; remove it if/when
  upstream ships the behavior (Alpine package users would get it via a package version bump + app version bump).
- **The watcher's failure class is nearly empty, by construction** (the regeneration-failure guard is cheap insurance,
  not a fix for a real path): the options cannot change under a running app (supervisor validates at save time -
  `api/apps.py` options endpoint - and only hands the new options.json to the app at its next start), so all
  config-content rejections fire at boot. Device-resolution failures are not failures (pass-through path). The one
  reachable mid-run failure: two configured symlink names of the same physical drive (drives can carry several by-id
  links - e.g. `ata-*` and `usb-*` for one disk) where one was detached at boot; once the drive is plugged in, the
  duplicate-entry rejection fires per tick (ERROR lines every 30 s until the user fixes the config - spammy but
  truthful, accepted). "Known-good configuration" = the args file (re-read by the run script on every (re)start) plus
  the running daemon's argv, both untouched on failure; the persistent source of truth is `options.json` on /data.

## Local-lab host interference on this dev machine

(The general principle — interference sweep, event-based assertions, side-effect-free probes — is repository-wide, see
the repository-root `KNOWLEDGE.md`; the preflight sweep lives in the lab hook `.mise/tasks/lab/hd-idle.sh`.)

Checked on the development machine (2026-10, ostree-based Fedora): no udisks2 (hence no GNOME-Disks drive settings that
get re-applied on hotplug), no TLP/laptop-mode/powertop service, no smartd, `hdparm` not installed and
`/etc/hdparm.conf` inert (commented), and the disks' SCSI device runtime-PM `power/control` is `on` (Fedora udev default
for storage) — i.e. no USB autosuspend that could break SG_IO. Nothing interferes with spindown tests here today; the
preflight sweep guards against that changing.
