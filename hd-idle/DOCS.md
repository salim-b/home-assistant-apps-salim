# Home Assistant app: hd-idle

## Configuration

Drives are configured in the app's [settings](/config/app/f8b2d53d_hd-idle/config). Each entry in the **Drives** list manages one drive; see the field
descriptions in the configuration dialog for details. Saving configuration changes restarts the app, which re-validates
the configuration and regenerates the hd-idle command line.

### Configuration modes

**Opt-in** (default): only the listed drives are spun down, each with its own idle time (required) and optional command
type / power condition. All other disks - including anything that appears on the system later - are never touched. This
is the recommended, fail-safe mode.

**Opt-out**: all monitored drives follow the global defaults (**Default idle time**, **Default command type**,
**Default power condition**). Drive entries override these per drive, and an entry with idle time `0` excludes that drive.
Important on Home Assistant OS: device access is only granted for drives listed in the **Drives** list, so drives
without a list entry cannot actually be spun down - they produce a warning in the app log once per idle cycle. List
every drive you want spun down (leaving its other fields empty to follow the defaults) and use `idle: 0` entries for exclusions.

### Selecting drives

The drive dropdown lists the system's block devices by their stable `/dev/disk/by-id` paths - these survive re-plugging and reboots, even
when the kernel name (`/dev/sda`, `/dev/sdb`, ...) changes. Select the **disk itself**, never a partition (by-id paths ending in `-part...`): the app
needs the whole disk, and the startup validation rejects partition entries with an explanatory message.

On startup the app logs an inventory of all detected `sd*` disks (model and by-id path) and the mapping of every configured
drive to its kernel name, so log lines like `sda spindown` can be attributed:

```text
Drive /dev/disk/by-id/usb-WD_Elements_1234567890AB-0:0 -> sda
```

### Command types

hd-idle can send the spin-down command via two APIs:

- **`scsi`** (default): a SCSI START STOP UNIT command. Works for everything behind the SCSI translation layer -
  typically all USB drives.
- **`ata`**: the native ATA STANDBY command (what `hdparm -y` does). Needed for SATA drives and some USB bridge chips (e.g. JMicron
  controllers); it requires elevated privileges, which the app requests. If a USB drive refuses to spin down with `scsi`, try
  `ata`.

The **power condition** only matters for real SCSI/SAS drives (rare on Home Assistant); leave it at `0`.

### System disk protection

The drive(s) Home Assistant runs from are excluded from spin-down by three independent layers:

1. The supervisor never grants the app device access to devices the system uses - a configured system disk is rejected
   at startup with an explanatory message.
2. The app resolves the boot device (kernel `root=` parameter) plus all `hassos-*` partitions at startup and pins those disks to "never
   spin down" (logged as `Excluding the system disk(s) ...`) - this also covers USB-booted systems, where the system disk is an `sd*` disk hd-idle would
   otherwise monitor.
3. hd-idle itself only ever monitors `sd*` disks; system disks on SD/eMMC/NVMe are out of its reach anyway.

### Hotplug behavior

Drives are granted device access dynamically by the supervisor - including when re-attached later, without an app
restart. A drive that is detached when the app starts is passed to hd-idle for runtime resolution (by-id symlinks are
re-resolved once the drive appears). The app also periodically re-resolves its configured drives: after moving drives
between ports or machines - which changes their kernel names (`/dev/sda`, `/dev/sdb`, ...) - hd-idle is restarted automatically with the
updated configuration (within about half a minute); no manual restart is needed.

## Activity log and debugging

With **Activity log** enabled, hd-idle writes per-drive spin-up records (running/standby durations) to `/data/hd-idle.log` in the app's
persistent data directory. Spin-down/spin-up events always appear in the app log; **Debug mode** adds a
per-monitoring-cycle state dump for every disk (useful when drives refuse to spin down).

## Limitations

- **Only `sd*` disks are monitored** (see the README): NVMe, SD/eMMC and loop devices are never touched, and NVMe drives
  cannot be managed.
- **Do not run SMART-polling tools alongside** (smartmontools and apps built on it): their polling keeps waking drives
  and their activities are invisible to hd-idle. The upstream hd-idle documentation says the same about disk monitoring
  tools generally.
- **Spin-up wear**: frequent spin-down/spin-up cycles stress the spindle motor and bearings; keep idle times at 3-5
  minutes minimum (hd-idle's default is 10).
- **Ignore spin-down detection** is a global hd-idle setting and cannot be set per drive (upstream limitation).

## Security notes

- The app requests `SYS_RAWIO` because hd-idle's `ata` command type uses SCSI passthrough commands (ATA PASS-THROUGH) that the kernel
  only permits with that capability; the default `scsi` command type works without it. Drive access itself is granted per
  configured drive by the supervisor's device policy - the system disk cannot be granted at all.
- The hd-idle daemon runs under its own AppArmor sub-profile with all networking denied; it talks to no network service
  whatsoever.
- The app never writes to managed drives: it only issues standby commands and reads state.
