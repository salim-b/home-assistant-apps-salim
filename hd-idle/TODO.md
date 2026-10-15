# TODOs

Short dev items first; resolved items at the bottom. Underlying technical facts and root causes live in `KNOWLEDGE.md`.

## Tasks

- Upstream: hd-idle's `-s 1` re-resolves only *unresolved* device entries and never re-verifies already-resolved ones
  (`resolveSymlinks()` skips entries with a populated `Name`). A small upstream change (re-verify resolved symlinks each
  cycle, update entries whose resolution changed) would let us remove the app's `hd-idle-watch` service (see
  `KNOWLEDGE.md`).

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

- AppArmor profile verified on the real device (odroid-m1, 2026-10-15): the `hdidle` sub-profile (`cx` transition +
  `deny network`) and the `/dev/sd*` ioctl path work under real enforcement. Proven functionally rather than via audit
  logs (HAOS produces no AppArmor audit logs, and the SSH app context cannot read apparmorfs): `test:live` ran the
  daemon in opt-in mode against all nine glob-selected USB disks and every single drive issued its daemon-driven
  spindown event - device cgroup grant, `/dev` node open, SG_IO `START STOP UNIT` and command execution all happened
  under the enforced profile. Zero error/denial lines in the app log and dmesg.

- `test:live` does real spindown checks (`.mise/tasks/test/live/hd-idle.sh`): `LIVE_HDIDLE_LABEL_GLOB` selects the
  drives by filesystem label (only disks whose labeled partitions ALL match the glob; non-`sd*` disks and disks hosting
  non-matching labels are excluded - the glob is a test-target selector, not a safety boundary), generates opt-in test
  options with a 30 s idle on the fly and asserts the boot (managed-disk set exactly equal to the discovery, by-id to
  kernel mapping) plus per-drive daemon-issued spindown events within a 300 s window. HAOS ships no docker CLI, so the
  lab's forced `hd-idle -t` single-shot check is not reproducible on the device - the daemon's own events are the
  stronger end-to-end assertion anyway.
