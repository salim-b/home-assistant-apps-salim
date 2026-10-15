<!-- https://developers.home-assistant.io/docs/apps/presentation#keeping-a-changelog -->

# Changelog

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
