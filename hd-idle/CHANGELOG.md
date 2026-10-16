<!-- https://developers.home-assistant.io/docs/apps/presentation#keeping-a-changelog -->

# Changelog

## 0.1.5

- Change: the **Configuration mode** option is removed. The app now manages exactly the listed drives, and every listed
  drive follows the global defaults (default idle time, default command type, default power condition) wherever its own
  fields are left empty - the convenience of the former opt-out mode is now simply how the app works. Unlisted drives
  are never spun down: Home Assistant OS grants device access per listed drive only, so spinning down unlisted drives
  was never realizable - previously the daemon attempted it once per idle cycle and logged 'operation not permitted'
  each time. The former opt-in rejection of entries without an idle time is gone (the default idle time fills them). A
  stored `mode` key from an older version is simply ignored (the supervisor logs a harmless one-line warning about the
  stale key; re-saving the options clears it). Migration device-verified 2026-10-16.

## 0.1.4

- Fix: the hd-idle and hd-idle-watch services now start only after the boot-time configuration phase completed (s6-rc
  dependency on the built-in base bundle, like the nfs-server app's services). Previously the daemon could start before
  the generated configuration existed, crash on startup (`./run: line 9: /etc/hd-idle.args: No such file or directory`)
  and only start once s6 restarted it - a raw error line in the app log on every boot, and a slightly late daemon.
- Log quality: the boot log now states the configuration mode prominently; the "no drives configured" message is phrased
  per mode - in `opt-out` mode it explains that unlisted drives follow the global defaults but cannot actually be
  reached (Home Assistant OS grants device access per listed drive only), instead of the misleading "will not spin down
  anything"; the daemon start line includes the mode.

## 0.1.3

- Fix: the AppArmor profile now grants `CAP_SYS_RAWIO` (`capability sys_rawio,` in the top and the daemon sub-profile).
  AppArmor mediates the kernel's capable() check itself (the security_capable LSM hook), so without the rule every
  non-read-safe SCSI command failed with EPERM even though the container carried the capability - hd-idle's `ata`
  spindown path (ATA PASS-THROUGH) and smartctl's ATA commands were affected, while the `scsi` path (START STOP UNIT, in
  the kernel's read-safe list) worked.
- New option **Disable drive power management** (default on): the app issues `apm,off` and `standby,off` (via
  smartmontools) for every managed drive at app start and whenever a drive (re)appears, so hd-idle's idle time is the
  only thing that puts a drive to sleep - this stops some WD USB bridge firmwares from waking drives shortly after an
  external spindown (an effect invisible to I/O monitoring). Bridges that do not forward APM produce a logged one-time
  failure; the standby-timer disable is honored by all tested bridges.
- Robustness: the hd-idle-watch service compares and re-syncs both generated files (command line + drives list) every
  cycle, so an interrupted configuration install self-heals on the next tick instead of silently skipping the drive-PM
  treatment for affected drives; hd-idle-genargs now rejects option values containing whitespace (defense in depth
  against hand-edited options files); a hd-idle-pmfix failure at app start is logged as a warning instead of failing the
  boot (consistent with the watcher's re-application path).
- Documentation: shorter, clearer option descriptions in the settings dialog; the **Ignore spin-down detection**
  description now warns about possible extra wear on some bridges.
- Performance: the watcher's per-tick configuration regeneration skips the boot-only disk inventory walk (two process
  spawns per disk plus one per by-id link per disk), and the healthcheck probe scans `/proc` with the read builtin
  instead of one `cat` per process - cutting the app's periodic process churn by roughly 90% (no behavior change).

## 0.1.2

Development version, never published - consumed by a transitory test build during the 0.1.3 branch's development.

## 0.1.1

Development version, never published - consumed by a transitory test build during the 0.1.3 branch's development.

## 0.1.0

- Initial release.
- hd-idle daemon watching disk activity (`/proc/diskstats`) and spinning down idle `sd*` disks (USB, SATA) via SCSI or
  ATA commands.
- Per-drive configuration (idle time, command type, power condition) via stable `/dev/disk/by-id` device selection;
  opt-in mode (only listed drives are touched) and opt-out mode (global defaults with per-drive overrides/exclusions).
- System disk always excluded (supervisor device policy, boot-device/`hassos-*` detection, hd-idle's `sd*`-only
  monitoring scope).
- Hotplug-aware: dynamic device-access grants and runtime by-id re-resolution; drives moved between ports/machines are
  picked up automatically (watcher restarts hd-idle with the updated kernel names).
- Detailed activity log (optional, `/data/hd-idle.log`), debug mode, ignore-spin-down-detection (global hd-idle
  setting).
- hd-idle apk package pinned (1.22-r7): Alpine-side package updates become explicit app releases, guided by the CI drift
  check (see the repository-root `KNOWLEDGE.md` apk package version policy).
- Custom AppArmor profile; the daemon runs network-free under its own sub-profile.
- Debug mode emits hd-idle's `-d` flag once (it was previously passed twice).
