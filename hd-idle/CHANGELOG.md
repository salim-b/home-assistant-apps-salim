<!-- https://developers.home-assistant.io/docs/apps/presentation#keeping-a-changelog -->

# Changelog

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
