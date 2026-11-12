# Home Assistant app: hd-idle

Spin down idle USB and SATA hard disk drives automatically.

![Supports aarch64 Architecture][aarch64-shield] ![Supports amd64 Architecture][amd64-shield]

## Features

- **Automatic spin-down**: Runs [hd-idle](https://github.com/adelolmo/hd-idle), which watches I/O activity per disk
  (`/proc/diskstats`) and sends SCSI/ATA standby commands to hard disk drives that have been idle for their configured
  time.
- **Per-drive configuration**: Every managed drive gets its own idle time, command type, power condition and
  power-management treatment, selected from a dropdown of the system's drives by their stable `/dev/disk/by-id` paths.
- **Drive list with global defaults**: List each drive once – it follows the global default idle time unless configured
  individually (`0` = never spin down). Unlisted drives are never touched.
- **Hotplug-aware**: Drives are granted device access dynamically (including after re-plugging), and disk IDs are
  re-resolved to their device paths at runtime – drives moved between ports or machines are picked up automatically
  without a restart.
- **System disk is always protected**: The drive(s) Home Assistant runs from are excluded by three independent layers
  (details in the [documentation](/config/app/f8b2d53d_hd-idle/documentation)) – regardless of whether Home Assistant
  boots from USB.
- **Hardened runtime**: Ships a custom [AppArmor](https://apparmor.net/) profile; the hd-idle daemon itself opens no
  sockets (the app's only network traffic is supervisor-API HTTP and DNS resolution).

## Limitations

- **Only `sd*` disks are monitored**: NVMe, SD/eMMC and loop devices are never touched (details in the
  [documentation](/config/app/f8b2d53d_hd-idle/documentation)).
- **Do not run other disk-monitoring tools alongside**: SMART polling keeps waking the drives.
- **Spin-up wear**: Shorter idle times result in more drive spin-ups, which eventually wear out the spindle motor and
  bearings; keep it at 3–5 minutes minimum (hd-idle's default is 10 minutes).

## Documentation

For usage, configuration and security notes, see the [**Documentation**](/config/app/f8b2d53d_hd-idle/documentation).

[aarch64-shield]: https://img.shields.io/badge/aarch64-yes-green.svg
[amd64-shield]: https://img.shields.io/badge/amd64-yes-green.svg
