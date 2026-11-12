# Home Assistant app: hd-idle

## Configuration

Drives are configured in the app's [settings](/config/app/f8b2d53d_hd-idle/config). Each entry in the **Drives** list
manages one drive; see the field descriptions in the configuration dialog for details. Saving configuration changes
restarts the app, which re-validates the configuration and regenerates the hd-idle command line.

### Drive list semantics

Every **listed** drive is managed with the settings configured on its own entry (**Idle time**, **Command type**,
**Power condition** – all required); an idle time of `0` never spins it down, and unlisted drives – including anything
that appears on the system later – are never touched. Only listed drives receive device access on Home Assistant OS,
which also keeps the system disk out of reach.

### Selecting drives

Pick each drive from the dropdown and select the **disk itself**, never a partition — see the **Drives** field
description in the options UI for the details. The by-id paths survive re-plugging and reboots even when the kernel name
changes.

On startup the app logs an inventory of all detected `sd*` disks and the mapping of every configured drive to its kernel
name, so log lines like `sda spindown` can be attributed. Each inventory line shows the drive model, its by-id path and
— when set – the label of the drive's first labeled partition (filesystem label preferred, GPT partition label as
fallback; an unpartitioned disk shows its whole-disk filesystem label) – usually the name the drive carries in file
managers:

```text
# with command type `scsi`
[10:30:00] INFO:   sda: Elements 25A3 (by-id: usb-WD_Elements_1234567890AB-0:0, label (sda1): my_movies)
# with command type `ata`
[22:49:21] INFO:   sda: Elements 25A3 (by-id: ata-WDC_WD160EDGZ-0AB4567_876543XY, label (sda1): my_movies)
```

### Drive power management

Drives – and some USB bridges – run their own power management that can conflict with hd-idle, so the app disables it by
default (the drive-PM treatment; every managed drive gets it unless it opts out). The per-drive **Keep drive power
management** switch opts individual drives out – switch it on for drives that must keep their own power management; its
field description in the options UI has the why and the details.

### Command types

The spin-down command is sent via one of two APIs – **`scsi`** or **`ata`**; the **Command type** and **Power
condition** field descriptions in the options UI explain both and when to use which.

### System disk protection

The drive(s) Home Assistant runs from are excluded from spin-down by three independent layers:

1. The supervisor never grants the app device access to devices the system uses – a configured system disk is rejected
   at startup with an explanatory message.
2. The app resolves the boot device (kernel `root=` parameter) plus all `hassos-*` partitions at startup and pins those
   disks to "never spin down" (logged as `Excluding the system disk(s) ...`) – this also covers USB-booted systems,
   where the system disk is an `sd*` disk hd-idle would otherwise monitor.
3. hd-idle itself only ever monitors `sd*` disks; system disks on SD/eMMC/NVMe are out of its reach anyway.

### Hotplug behavior

Drives are granted device access dynamically by the supervisor – including when re-attached later, without an app
restart. A drive that is detached when the app starts is passed to hd-idle for runtime resolution (by-id symlinks are
re-resolved once the drive appears) – and hd-idle applies its configured idle time to it immediately upon resolution,
without waiting for a configuration restart. The app also periodically re-resolves its configured drives: after moving
drives between ports or machines – which changes their kernel names (`/dev/sda`, `/dev/sdb`, ...) – hd-idle is restarted
automatically with the updated configuration (within about half a minute); no manual restart is needed.

## Activity log and debugging

Spin-down/spin-up events always appear in the app log. **Debug mode** adds a per-monitoring-cycle state dump for every
disk (useful when drives refuse to spin down); **Activity log** writes per-drive run/standby records to
`/data/hd-idle.log` – both field descriptions in the options UI have the details.

## Limitations

- **Only `sd*` disks are monitored**: hd-idle reads `/proc/diskstats` and only acts on SCSI-layer disks (`sdX`) and
  device-mapper devices attributed to them; NVMe, SD/eMMC and loop devices are never touched, and NVMe drives cannot be
  managed.
- **Do not run SMART-polling tools alongside** (smartmontools and apps built on it): their polling keeps waking drives
  and their activities are invisible to hd-idle. The upstream hd-idle documentation says the same about disk monitoring
  tools generally.
- **Spin-up wear**: frequent spin-down/spin-up cycles stress the spindle motor and bearings; keep idle times at 3-5
  minutes minimum (hd-idle's default is 10).
- **Ignore spin-down detection** is a global hd-idle setting and cannot be set per drive (upstream limitation), and can
  cause extra wear on some bridges (see its description in the options UI).

## Security notes

- The app requests `SYS_RAWIO` because hd-idle's `ata` command type uses SCSI passthrough commands (ATA PASS-THROUGH)
  that the kernel only permits with that capability; the `scsi` command type works without it. Drive access itself is
  granted per configured drive by the supervisor's device policy – the system disk cannot be granted at all.
- The hd-idle daemon runs under its own AppArmor sub-profile with all networking denied; it talks to no network service
  whatsoever.
- The app never writes data to managed drives: it issues standby commands and, unless a drive opts out via the **Keep
  drive power management** switch, ATA SET FEATURES requests that switch off the drive's own power management – but no
  data is ever written.
