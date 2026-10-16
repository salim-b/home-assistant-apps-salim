# Home Assistant app: hd-idle

## Configuration

Drives are configured in the app's [settings](/config/app/f8b2d53d_hd-idle/config). Each entry in the **Drives** list
manages one drive; see the field descriptions in the configuration dialog for details. Saving configuration changes
restarts the app, which re-validates the configuration and regenerates the hd-idle command line.

### Drive list semantics

Every **listed** drive is managed: it follows the global defaults (**Default idle time**, **Default command type**,
**Default power condition**) wherever its own fields are left empty, an idle time of `0` never spins it down, and
unlisted drives - including anything that appears on the system later - are never touched. Only listed drives receive
device access on Home Assistant OS, which also keeps the system disk out of reach.

### Selecting drives

Pick each drive from the dropdown, which lists the system's block devices by their stable `/dev/disk/by-id` paths (these
survive re-plugging and reboots, even when the kernel name changes); select the **disk itself**, never a partition. See
the **Drives** field description in the options UI for the details.

On startup the app logs an inventory of all detected `sd*` disks (model and by-id path) and the mapping of every
configured drive to its kernel name, so log lines like `sda spindown` can be attributed:

```text
Drive /dev/disk/by-id/usb-WD_Elements_1234567890AB-0:0 -> sda
```

### Drive power management

Drives run their own power management (an APM level and an internal standby timer) that can conflict with hd-idle - some
USB bridge firmwares wake the drive again shortly after an external spindown, invisibly to the app's I/O monitoring. The
**Disable drive power management** option (on by default) disables both for every managed drive; see its field
description in the options UI for the details.

### Command types

The spin-down command is sent via one of two APIs - **`scsi`** (default) or **`ata`**; see the **Command type** and
**Power condition** field descriptions in the options UI for the details and when to use which. If a USB drive refuses
to spin down with `scsi`, try `ata`.

### System disk protection

The drive(s) Home Assistant runs from are excluded from spin-down by three independent layers:

1. The supervisor never grants the app device access to devices the system uses - a configured system disk is rejected
   at startup with an explanatory message.
2. The app resolves the boot device (kernel `root=` parameter) plus all `hassos-*` partitions at startup and pins those
   disks to "never spin down" (logged as `Excluding the system disk(s) ...`) - this also covers USB-booted systems,
   where the system disk is an `sd*` disk hd-idle would otherwise monitor.
3. hd-idle itself only ever monitors `sd*` disks; system disks on SD/eMMC/NVMe are out of its reach anyway.

### Hotplug behavior

Drives are granted device access dynamically by the supervisor - including when re-attached later, without an app
restart. A drive that is detached when the app starts is passed to hd-idle for runtime resolution (by-id symlinks are
re-resolved once the drive appears) - and hd-idle applies its configured idle time to it immediately upon resolution,
without waiting for a configuration restart. The app also periodically re-resolves its configured drives: after moving
drives between ports or machines - which changes their kernel names (`/dev/sda`, `/dev/sdb`, ...) - hd-idle is restarted
automatically with the updated configuration (within about half a minute); no manual restart is needed.

## Activity log and debugging

With **Activity log** enabled, hd-idle writes per-drive spin-up records (running/standby durations) to
`/data/hd-idle.log` in the app's persistent data directory. Spin-down/spin-up events always appear in the app log;
**Debug mode** adds a per-monitoring-cycle state dump for every disk (useful when drives refuse to spin down).

## Limitations

- **Only `sd*` disks are monitored** (see the README): NVMe, SD/eMMC and loop devices are never touched, and NVMe drives
  cannot be managed.
- **Do not run SMART-polling tools alongside** (smartmontools and apps built on it): their polling keeps waking drives
  and their activities are invisible to hd-idle. The upstream hd-idle documentation says the same about disk monitoring
  tools generally.
- **Spin-up wear**: frequent spin-down/spin-up cycles stress the spindle motor and bearings; keep idle times at 3-5
  minutes minimum (hd-idle's default is 10).
- **Ignore spin-down detection** is a global hd-idle setting and cannot be set per drive (upstream limitation), and can
  cause extra wear on some bridges (see its description in the options UI).

## Security notes

- The app requests `SYS_RAWIO` because hd-idle's `ata` command type uses SCSI passthrough commands (ATA PASS-THROUGH)
  that the kernel only permits with that capability; the default `scsi` command type works without it. Drive access
  itself is granted per configured drive by the supervisor's device policy - the system disk cannot be granted at all.
- The hd-idle daemon runs under its own AppArmor sub-profile with all networking denied; it talks to no network service
  whatsoever.
- The app never writes to managed drives: it only issues standby commands and reads state.
