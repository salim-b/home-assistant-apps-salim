# TODOs

Short dev items first; resolved items at the bottom. Underlying technical facts and root causes live in `KNOWLEDGE.md`.

## Tasks

- Drive-PM treatment blind spot (see `KNOWLEDGE.md` §`Drive-PM treatment`): a drive that reconnects under the SAME
  kernel name (its bridge power-cycled it) is invisible to hd-idle-pmfix's `--since` diff and stays untreated until the
  next app restart. Find a detection mechanism that respects the redundant-treatment risk (device-verified motor starts,
  see `KNOWLEDGE.md`).

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

- Upstream: file a feature request for per-drive (and/or global) disabling of the drives' own power management - the ATA
  SET FEATURES APM level and standby timer equivalents (`hdparm -B off` / `smartctl -d sat -s apm,off` and
  `-s standby,off`). hd-idle v1.22 only issues standby commands and has zero APM/standby-timer code (verified in
  `main.go`/`hdidle.go`); drives with their own power management active can wake themselves up again after an external
  standby command entirely invisibly to the host (no `/proc/diskstats` activity - observed on a test device for three of
  nine drives, 2026-10-15; an earlier setup.s fix for the same drives was disabling APM + standby timer before forcing
  standby). Note the empirical complication found on another host: behind some WD USB bridges the APM feature page is
  filtered out entirely ("APM feature is: Unavailable"), so the feature would need graceful handling of
  unsupported/filtered feature pages. Related: hd-idle's default `scsi` command type was a silent no-op (GOOD status, no
  drive action) for such a bridge under one host stack while `ata` worked - worth including in the request the
  observation that a "command failed/no-op" signal would help (hd-idle currently marks drives spun down even when the
  command has no effect).

- Design a better logo. Maybe a HDD that sleeps/snores ("zzzz")?

- Re-assess [`rust-idle`](https://github.com/Piezoid/rust-idle) as an alternative/supplement to hd-idle once a new
  version is released (if that ever happens – the last release is 2022-05). Facts below verified against the repo tip
  (commit 288d283, 2024-09-08) in 2026-10. The spindown command path decides most of the comparison:
  `src/sys.rs::spindown_disk()` issues a SCSI START STOP UNIT (0x1B, fixed power condition 0) via SG_IO on the
  `/dev/sdX` node, and that is its only spindown mechanism - the explicit "//TODO: implement for ATA/USB devices"
  comment sits right above it; there is no ATA path at all (no ATA PASS-THROUGH, no hdparm-style HDIO commands, no
  per-device command type).

  - Pros (honest): the one feature hd-idle lacks entirely - optional `syncfs()` + BLKFLSBUF of the drive's filesystems
    right before the spindown and/or on spin-up detection (the `s`/`S` config flags), flushing dirty pages so late
    writeback cannot wake the drive again; runtime auto-adoption of newly appeared drives with the current default flags
    (but per-drive configs resolve by kernel name once at startup, so a drive re-appearing under a NEW name drops to the
    defaults - including drives explicitly excluded with idle 0, a worse failure mode than hd-idle's stale-name behavior
    for our exclusion semantics); no `-I` equivalent at all (hd-idle's re-assertion flag is a wear generator on bridges
    where redundant STOP commands half-start the motor, per `KNOWLEDGE.md` §`Drive-PM treatment`, so its absence is no
    loss); genuinely tiny (2 dependency crates, zero-allocation steady state, ~71 kB binary with nightly build-std per
    upstream claim vs the ~1.6 MB stripped Go binary - against the resolved long-running-footprint review below this
    amounts to a small RSS saving at best); permissive MIT license (vs GPL-3.0-only) should forking ever become the
    path; its only command (START STOP UNIT) is in the kernel's read-safe list, so a rust-idle-based app would need no
    SYS_RAWIO (security rating +1) - but only as long as no drive-PM treatment (smartctl ATA SET FEATURES) is ported,
    which is precisely the feature this app's users rely on.

  - Cons (honest): effectively unmaintained (last commit 2024-09-08, a single v0.1.0 release 2022-05 while Cargo.toml
    already says 0.1.1, 3 stars, no open issues; the author frames the project as an exercise "to see how well rust
    fares"; contrast: hd-idle upstream is active, last commit 2026-06), with README-vs-code drift (the "monitors
    partitions" feature line is stale since the 2024-09-08 "track disks, not partitions" commit switched to disk-level
    counters); its SCSI-only path is exactly the one our testing found to be a silent no-op on some WD USB bridges
    (`KNOWLEDGE.md` §`Drive-PM treatment`) while hd-idle's `ata` path worked there - on this app's primary target
    hardware rust-idle cannot spin the drives down at all; fixed power condition 0 (real SCSI/SAS disks need 2 or 3, see
    the hd-idle README); no activity logfile with running/stopped statistics and no single-shot mode (the lab smoke test
    and manual diagnostics use both); disk-level activity counters - the opposite of hd-idle's partition/dm attribution,
    chosen upstream precisely because monitoring daemons dirty disk-level counters (smartd/udisks false positives);
    tested on x86_64 only per README while aarch64 is the main HA device target; no Alpine package (AUR only), so the
    app image would have to build from source - a cargo toolchain in the Docker build and a crates.io supply chain
    instead of the apk-pinning + drift-check policy (nightly toolchain pin + `-Z build-std` per build.sh for the
    advertised size; a plain stable cargo build also works but yields a larger binary); no skew/suspend-detection state
    reset (after host resume it can keep believing an actually-spinning drive is idle - the same stale-belief class the
    WD-bridge findings document for hd-idle).

  - Current assessment: not worth replacing the hd-idle CLI here, and given the dormancy plus the SCSI-only path
    probably not worth a separate app right now either - the wins are marginal (sync flags, smaller daemon) while
    everything else is regression on this app's target hardware. Should it ever be pursued despite that, it belongs in a
    SEPARATE app (own config.yaml, device options, AppArmor profile), never as a CLI swap in this one - the app-side
    machinery (hd-idle-genargs/hd-idle-watch/hd-idle-pmfix) is built around hd-idle's CLI semantics. One thing survives
    this assessment regardless: the sync-before-spindown/spin-up idea is a legitimate hd-idle upstream feature request
    (could be folded into the upstream items in this section).

## Resolved

- Per-drive drive-PM treatment override (2026-10-16, v0.1.6): each drive-list entry gained a `disable_drive_pm` yes/no
  field (empty = follow the global option), emitted as the drives file's fourth column; hd-idle-pmfix decides per drive
  from it and runs unconditionally (a global-only bashio gate could not express per-drive overrides). A `list(yes|no)?`
  dropdown instead of a `bool?` because an untouched optional checkbox is visually indistinguishable from an explicit
  "off" while unset - and jq's `// empty` cannot distinguish absent from an explicit false (both: `KNOWLEDGE.md`
  §`bashio option parsing`). Verified via a genargs/pmfix decision-matrix run against the pinned base image (options
  stubbed by seeding bashio's options cache; see the repository-root `KNOWLEDGE.md` base-image gotchas) and the lab boot
  with a configured override drive; the lab spindown smoke test itself needs a real spindownable drive and stays a
  device-side check.

- Configuration mode switch dropped (2026-10-16, v0.1.5): single mode - listed drives follow the global defaults where
  their fields are empty (default_idle alive for all listed drives; the former opt-in idle-less rejection is gone), the
  global idle is pinned to 0 so unlisted and runtime-appearing drives are never touched (the former opt-out EPERM churn
  is gone), system-disk pins kept as defense in depth, and detached-at-boot drives carry their effective idle in the
  passthrough entry (no watcher restart needed for the value). A stored mode key is inert (one-line supervisor warning,
  device-verified; see the repository-root KNOWLEDGE.md options bullet). Migration device-verified.

- Long-running footprint review (2026-10-15): taken - the genargs inventory walk (boot-time UX) is now guarded off in
  quiet mode (~290 process spawns per watcher tick eliminated, dominant churn source) and the healthcheck scans /proc
  with the read builtin (one spawn per checked PID eliminated); lab-verified, no behavior change (the inventory log line
  is boot-only, and args-file content is unchanged). Considered and rejected: batching the per-disk jq calls into one
  @tsv call (~27 fewer spawns for nine disks; parsing subtlety disproportionate after the guard), raising or backing off
  the watcher's 30 s interval (changes the documented hotplug pickup latency), a by-id hash pre-gate before regeneration
  (complexity disproportionate now), and RAM trimming (peaks are transient; the resident set is the watcher bash and the
  upstream Go daemon only). The daemon's poll interval is upstream and scales with user-configured idle times - not ours
  to change.

- Round 2 review applied (2026-10-15): the SG_IO section documents the kernel's EPERM fall-through mechanism
  (`scsi_cmd_allowed()` -> `return open_for_write`, restored as slimming collateral); the `-t` KNOWLEDGE note reflects
  the lab smoke test's docker-exec caller; boot-time hd-idle-pmfix failure is non-fatal (consistent with the watcher,
  CHANGELOG 0.1.3); pmfix's result classification greps use `-iE` (POSIX alternation); README wording (the daemon opens
  no sockets; ASCII hyphen in "3-5"); lab-hook comment corrected (single-shot uses the GLOBAL default command type).
  Durable verified-OK facts from the round: the drives-file derivation's nonsuffix case branch exists for the watcher's
  /tmp candidate naming; a genargs failure after the args write converges via the dual-cmp (or boot restart).

- Code review + doc/comment cleanup (2026-10-15, v0.1.3) done: full read-only review of all scripts, profile, config and
  Dockerfile (shellcheck/bash -n clean); both must-fix doc defects fixed (the SG_IO capability guidance contradicted the
  shipped profile; the dangling same-kernel-name TODO reference), both behavioral nice-to-haves implemented and
  lab-verified (the watcher compares/re-syncs both generated files; hd-idle-genargs rejects whitespace in emitted
  tokens), and the comment slimming landed (single canonical homes per the placement rule, references elsewhere; comment
  share 29-73% -> 21-54%; zero behavior verified via comment-stripped diffs). Accepted residual risks: the crash window
  between the watcher's second mv and hd-idle-pmfix defers treatment to the next app restart (documented fallback); the
  `hd-idle -t` KNOWLEDGE section has no in-app caller (kept for manual debugging).

- AppArmor profile verified on a real device (2026-10-15): the `hdidle` sub-profile (`cx` transition + `deny network`)
  and the `/dev/sd*` ioctl path work under real enforcement. Proven functionally rather than via audit logs (HAOS
  produces no AppArmor audit logs, and the SSH app context cannot read apparmorfs): `test:live` ran the daemon in opt-in
  mode against all nine glob-selected USB disks and every single drive issued its daemon-driven spindown event - device
  cgroup grant, `/dev` node open, SG_IO `START STOP UNIT` and command execution all happened under the enforced profile.
  Zero error/denial lines in the app log and dmesg.

- `test:live` does real spindown checks (`.mise/tasks/test/live/hd-idle.sh`): `LIVE_HDIDLE_LABEL_GLOB` selects the
  drives by filesystem label (only disks whose labeled partitions ALL match the glob; non-`sd*` disks and disks hosting
  non-matching labels are excluded - the glob is a test-target selector, not a safety boundary), generates opt-in test
  options with a 30 s idle on the fly and asserts the boot (managed-disk set exactly equal to the discovery, by-id to
  kernel mapping) plus per-drive daemon-issued spindown events within a 300 s window. HAOS ships no docker CLI, so the
  lab's forced `hd-idle -t` single-shot check is not reproducible on the device - the daemon's own events are the
  stronger end-to-end assertion anyway.
