# TODOs

Short dev items first; resolved items at the bottom. Underlying technical facts and root causes live in `KNOWLEDGE.md`.

## Tasks

- Upstream: hd-idle's `-s 1` re-resolves only *unresolved* device entries and never re-verifies already-resolved ones
  (`resolveSymlinks()` skips entries with a populated `Name`). A small upstream change (re-verify resolved symlinks each
  cycle, update entries whose resolution changed) would let us remove the app's `hd-idle-watch` service (see
  `KNOWLEDGE.md`).

- Verify the AppArmor profile on the real device (odroid-m1) with the drives attached: the `hdidle` sub-profile (`cx` +
  `deny network`) and the `/dev/sd*` ioctl path are lab-untestable (no AppArmor enforcement in the lab). Profile changes
  need a `config.yaml` version bump to reach the device (the supervisor re-installs profiles on app *update*, not
  rebuild - see the repository-root KNOWLEDGE.md, AppArmor section).

- Extend `test:live` with real spindown checks once USB HDDs are attached to the odroid-m1: force a spindown via the app
  container's `hd-idle -t` (single-shot) and assert the standby state + the app log events. Needs a device-side hdparm
  check (no docker CLI on HAOS - probably via `ha apps logs` events only, or an exec-capable path).

- Monitor hd-idle upstream: v1.22 has no GitHub release (Alpine tracks the tag); Alpine-side package updates are caught
  automatically by the apk drift check (validate.py, daily CI cron) and released per the repository-root KNOWLEDGE.md
  workflow. Upstream *behavior* changes (new flags etc.) are read and adapted when such a release is made; a future
  version adding per-device `-I` or a config file would also relax the option schema. Worth filing upstream: per-device
  `-I` would make the global-only limitation moot for mixed setups.

- The supervisor's `device(subsystem=block)` dropdown lists partitions and loop devices alongside disks (filter is by
  udev subsystem only); users can pick a `-partN` entry, which our startup validation rejects with an explanatory
  message. Consider an upstream suggestion for a finer filter (e.g. `type=disk`) if the UX annoys real users.

- Design a better logo. Maybe a HDD that sleeps/snores ("zzzz")?

## Resolved

(none yet)
