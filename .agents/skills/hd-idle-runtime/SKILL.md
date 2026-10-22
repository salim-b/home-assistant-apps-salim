---
name: hd-idle-runtime
description: Runtime architecture and procedures for the hd-idle Home Assistant app — the
  hd-idle-genargs/drives/pmfix/watch flow, the --check baseline replay, SG_IO privileges, drive-ID conventions, and
  restart semantics. Use before touching hd-idle runtime code, its s6 services, or when debugging the app on a device.
---

# hd-idle runtime

## Architecture orientation

hd-idle has no config file — every setting is command line (facts: `hd-idle/KNOWLEDGE.md` §"CLI-only configuration").
The app generates that command line from the app options and keeps it in sync with the hardware:

- `/usr/bin/hd-idle-genargs` — the shared generator, used by cont-init and the watcher. Full generation (default) reads
  the options, resolves every configured device and writes three files; `--check` replays the recorded baseline with no
  option reads and no jq (facts: §"hd-idle-watch design").
- `/etc/hd-idle.args` — one line: the daemon argv, word-split by the s6 run script (every token must be space-free).
- `/etc/hd-idle.drives` — hd-idle-pmfix's interface: one `<kernel-name> <idle> <command-type> <pm-flag>` line per drive
  with effective values (format and semantics: §"Drive-PM treatment").
- `/etc/hd-idle.resolution` — the baseline state file, written LAST (commit point of the three-file install).
- `/usr/bin/hd-idle-pmfix` — drive-PM treatment via smartctl (§"Drive-PM treatment").
- s6-rc services: `hd-idle` (longrun; its run script reads the args file and `exec`s the daemon, so s6 signals hd-idle
  directly on stop and its stdout — spinup/spindown events, debug lines — lands in the app log) and `hd-idle-watch`
  (longrun, 30 s tick). cont-init: `/etc/cont-init.d/config.sh`.

Drive IDs: the options reference stable by-id paths (the physical `ata-<MODEL>_<SERIAL>` link and the `usb-*` enclosure
entry); hd-idle itself only ever sees kernel names. Regenerate the drive cheat sheet with
`mise run hd-idle-drives <host>` (writes `hd-idle/.drives.md`).

## Boot sequence

1. cont-init `config.sh` runs `hd-idle-genargs /etc/hd-idle.args` (full generation). Failure aborts the app boot; a
   missing args file afterwards makes the run script fail loudly (s6 restarts it).
2. `config.sh` then runs `hd-idle-pmfix /etc/hd-idle.drives` — non-fatal, the treatment is best-effort.
3. s6-rc starts the two longruns: `hd-idle` (the daemon) and `hd-idle-watch`.

## The change cycle (hd-idle-watch tick)

Why the watcher exists at all — hd-idle's `-s 1` never re-verifies resolved entries and the supervisor cannot help:
§"hd-idle-watch design".

1. `hd-idle-genargs --quiet --check` replays the baseline (file shas, system-disk set, per-device resolution outcomes):
   exit 0 = unchanged → next tick (no log output at all); exit 3 = changed (regeneration due); any other nonzero = check
   failure → log once, keep the current configuration.
2. On exit 3: full generation into /tmp candidate files.
3. If the regenerated args AND drives files match the installed ones, only the baseline state is stale (an interrupted
   install, or a resolution change that reverted): resync the state file only — no restart.
4. Otherwise install: copy the drives file to `.prev`, `mv` the candidates over args and drives, `mv` the state file
   last, run `hd-idle-pmfix <drives> --since <drives.prev>`, then `s6-svc -r /run/service/hd-idle`.

## Drive-PM treatment flow

- The drives file is the single source of truth for the effective per-drive decision: the global `disable_drive_pm`
  option is the default, per-drive yes/no overrides land in the pm-flag column. config.sh and the watcher therefore run
  `hd-idle-pmfix` unconditionally (a global-only gate could not express per-drive overrides); it skips pm-flag-0 drives.
- `--since <old-drives-file>` restricts treatment to lines that are NEW or CHANGED (a flipped pm-flag counts as changed,
  so a newly overridden drive is treated exactly once): redundant treatment of sleeping drives risks bridge-mediated
  motor starts (per-bridge reality: §"Drive-PM treatment" and §"USB-bridge behaviors").

## Debugging playbook

- Which log carries what: boot-time configuration messages and the drive inventory (by-id mapping) come from the
  non-quiet cont-init run; daemon stdout (`sda spindown`/`spinup` events, debug lines) and watcher notices land in the
  app log — unchanged watcher ticks are silent. The optional activity log (-l) is `/data/hd-idle.log`.
- A drive detached at boot is passed through for hd-idle's runtime resolution and recorded as PASSTHRU in the baseline;
  the watcher restarts hd-idle once it resolves.
- Two by-id symlinks for the same drive with one detached at boot: genargs' duplicate-entry rejection fires every tick
  (ERROR lines every 30 s until the config is fixed); the known-good configuration stays in place meanwhile.
- A restart does NOT spin up drives in standby: hd-idle sends no command at startup; idle timers restart and an
  activity-log "running" period spanning a restart is misaccounted.
- ata-path commands failing with EPERM: two independent gates must be open — `capability sys_rawio,` in BOTH profiles
  and `/dev/sd* rwk,` (§"SG_IO privileges").
- Power-state probes: `hdparm -C` wakes drives — use `smartctl -H -n standby` (§"USB-bridge behaviors").
- Manual single-shot: `hd-idle -t /dev/sdX` needs the full `/dev/` path and uses the global defaults only (§"hd-idle -t
  quirks"); in the lab drive it via `docker exec`.

## Extending

- Adding a per-drive option: add the schema field — optional per-drive dropdowns are `list(yes|no)?`, never `bool?`
  (§"bashio option parsing (list-of-object options)"); read it in hd-idle-genargs (space-free check), emit it as a
  drives-file column or argv token, and let the consumer (pmfix or hd-idle) decide per drive. Extend the genargs/pmfix
  decision matrix in the lab.
- hd-idle CLI/packaging: the Dockerfile pins apk package versions because genargs encodes the CLI — a package bump is a
  deliberate app release (root `KNOWLEDGE.md` §"apk package version policy"; release discipline: skill
  `ha-app-workflow`).
- Testing: the lab boots the full s6 tree and runs the genargs/pmfix/watch roundtrips, but the spindown smoke test needs
  real spindownable drives — a device-side check (skills `ha-app-lab-testing`, `ha-app-device-testing`).
