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

## bashio option parsing (list-of-object options)

`bashio::config '<list-option>'` returns one compact JSON object per line for list-of-object options: hd-idle-genargs
reads the `disks` option with
`while IFS= read -r entry; do ... bashio::jq "${entry}" '.field' ... done < <(echo "${DISKS}")` and relies on that shape
(verified against the v3.24 base image's bashio). If a bashio update ever changed the return shape (e.g. to
pretty-printed arrays), every drive entry would fail to parse - a lab boot with configured drives catches it.

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

## hd-idle-genargs quiet mode

`hd-idle-genargs --quiet` (the watcher's per-tick mode) suppresses ALL narrative/info output and the warning-level notes
for expected-transient states (a currently detached drive, a non-sd\* entry): both are surfaced once per boot by the
non-quiet cont-init run, and options cannot change mid-run (repository-root `KNOWLEDGE.md`
§`Supervisor: option schema quirks`), so repeating them every 30-s tick adds nothing. Errors always log, and invalid
configuration still exits nonzero in both modes: for cont-init that fails the app boot; for the watcher it means
regeneration failed and the current configuration (the args file plus the running daemon's argv - see
§`Automatic drive re-resolution` for when that can happen at all) stays as is.

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

Consequence for the profile - TWO independent gates, both must be open (device-verified 2026-10-15; the missing second
gate was the 0.1.3 fix): (1) the SG_IO ioctl itself is mediated only via the file's r/w permission (no per-command
mediation until AppArmor 4 - mechanism repository-wide, see the repository-root `KNOWLEDGE.md` §AppArmor), so
`/dev/sd* rwk,` (plus the `file,` blanket) covers it; (2) the kernel's `capable(CAP_SYS_RAWIO)` check inside
`scsi_cmd_allowed()` is mediated by AppArmor itself (repository-root `KNOWLEDGE.md` §AppArmor), so both profiles need
`capability sys_rawio,` - without that rule every ata-path command failed with EPERM even though the container carried
the capability.

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

(No in-app caller since the diagnostics build was reverted - kept as reference knowledge for manual debugging.)

## Verifying drive power states from the lab (USB bridges)

`hdparm -C` is **not a safe probe** for these drives: empirically (WD My Book 1230 / Elements 25A3 USB bridges on this
machine) it races the spin-down window (`SG_IO: bad/missing sense data` with sense key 70 00 02, ASC/ASCQ 04 01 = NOT
READY / "in process of becoming ready") and then **actually wakes the drive** (STOP → `smartctl -n standby` says SLEEP →
one `hdparm -C` → smartctl says active). Use **`smartctl -H -n standby`** instead (exit code 2 + "Device is in
STANDBY/SLEEP mode" without any media access) - that is what the lab hook does, with polling retries (desktop IO on
mounted drives may wake a drive between the STOP command and the probe).

## WD USB bridges lie about the drive's power state

The bridge firmware answers SCSI power-condition queries (the sense data behind `smartctl -H -n standby`, and hd-idle's
own state view is equally blind) from its **own** power-state model without consulting the drive: a drive that woke
itself up host-invisibly still reports STANDBY/SLEEP to every passive host-side probe (device-verified 2026-10-15: three
drives audibly spinning while `smartctl -n standby` and the app's diagnostics reported SLEEP, with frozen
`/proc/diskstats` counters). Consequences:

- No passive host-side probe can detect a host-invisible wake-up through these bridges. hd-idle's diskstats-based belief
  therefore never resets after such a wake: it never re-issues a spindown, and the drive can spin for hours while the
  app reports it as spun down.
- The only host-side truth is the ramp-up latency of a *real* read: an actually spinning drive answers in well under a
  second, an asleep drive takes the motor ramp (seconds). That probe is intrusive (it wakes an asleep drive) and must
  bypass the page cache (read far offsets; the first sector of a partition is typically cached from udev/blkid probing).
- `CHECK POWER MODE` (what `hdparm -C` sends) is forwarded to the drive - it is truthful but **wakes the drive** (see
  the section above), so it is likewise useless for passive observation.
- Prevention (the drive's own power management off + a spindown command class the bridge actually honors) beats
  detection here; see `TODO.md`.

## Drive-PM treatment (disable_drive_pm) - per-bridge reality

`hd-idle-pmfix` disables the drives' own power management (ATA SET FEATURES: APM level off + standby timer off) for
every managed drive at boot and on drive (re)appearance (the watcher re-applies to NEW/CHANGED drives only - redundant
treatment of sleeping drives risks bridge-mediated motor starts). Device-verified per-bridge matrix (a test device, five
WD USB bridges, 2026-10-15):

- **`standby,off`: honored by ALL five bridges** (My Book 1110/1230/25EE, Elements 107C, Ext HDD 1021) - the universally
  deliverable part.
- **`apm,off`: honored ONLY by the My Book 25EE bridge** ("APM disabled", reads back as Disabled); the other four fail
  with "scsi error aborted command" (107C, 1230) resp. "SAT command failed" (1110, 1021) - their APM feature page is
  filtered entirely (smartctl reads "APM feature is: Unavailable"). Non-fatal by design: logged once, everything else
  works.
- The treatment settings are volatile (reset on drive power cycle): re-applied at boot and on (re)appearance. **Known
  gap**: a drive whose bridge power-cycles it while it RECONNECTS UNDER THE SAME KERNEL NAME is invisible to the
  watcher's args diff and stays untreated until the next app restart (see TODO.md).
- **Redundant STOP commands are NOT harmless on all bridges**: a STOP sent to an already-asleep drive half-started the
  motor on the My Book 1230 bridge (audibly, ~21:43). Consequences verified in the wild: (a) hd-idle's `-I` (ignore
  spin-down detection) re-asserts spindowns to EVERY still-asleep drive once per idle interval (source-verified
  updateState(): `idleDuration > IdleTime && timeSinceLastSpunDown > IdleTime`) - on such bridges it is a wear
  generator, NOT production-safe; (b) each app restart makes the fresh daemon fire one spindown wave at ALL drives
  (fresh state), including already-asleep ones - the app restarts rarely (only on real config changes), so the cost is
  one wave per restart. Both documented in TODO.md as upstream-report items.

The drives file (`/etc/hd-idle.drives`, written by hd-idle-genargs next to the args file - the derivation of its name
from the args-file path is mirrored in the hd-idle-watch run script) is pmfix's machine-readable interface: one
`<kernel-name> <idle> <command-type>` line per drive with EFFECTIVE values (exclusions carry idle 0, entries without
explicit values carry the inherited defaults). pmfix treats only idle != 0 entries; with `--since <old-file>` only
drives whose line is NEW or CHANGED are treated.

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
  into candidate files, compare BOTH generated files (args + drives) against the installed ones, and only on an actual
  difference install them and restart just the hd-idle service (`s6-svc -r /run/service/hd-idle`) - the args file is
  installed last (commit point), so an interrupted install leaves the drives file stale behind it and the next tick's
  comparison re-syncs it. Unrelated churn therefore never triggers a restart, and `--quiet` makes unchanged 30-s ticks
  produce **no log output at all** (warnings/errors still surface; the new command line is logged by the hd-idle run
  script after each restart). Polling (not udev events) because mapping the host's `/run/udev` socket (`with_udev`) into
  an Alpine-based container for event-driven monitoring is version-fragile for zero gain - 30 s worst-case latency is
  fine for a maintenance action.
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
