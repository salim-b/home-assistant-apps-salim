# TODOs

Short dev items first; resolved items at the bottom. Underlying technical facts and root causes live in `KNOWLEDGE.md`.

## Tasks

- Plan: code review of the whole app + doc/comment cleanup. Comments are overly long and partially redundant
  (hd-idle-watch/run is 57% comment lines, config.sh 57%, pmfix 42%; several topics are told in full in 3-5 places).
  Policy: one canonical home per topic per the repo's information-placement rule, everything else becomes a short
  reference (`see hd-idle/KNOWLEDGE.md § "<heading>"`). Sequence:
  1. Review pass (read-only; findings logged here with file:line + severity must-fix/nice-to-have/upstream):
     hd-idle-genargs (opt-in/opt-out semantics, quoting, exit-code contract, quiet mode), hd-idle-watch/run (atomicity,
     change detection, pmfix --since diff), hd-idle-pmfix (smart() result classification, arg parsing), cont-init
     config.sh (failure propagation), hd-idle/run + healthcheck, s6-rc.d structure/dependencies, apparmor.txt (rule
     audit vs. actual file accesses), config.yaml, Dockerfile (apk pin policy).
  2. Establish canonical homes: move "why" narratives that exist only in code comments into `KNOWLEDGE.md` (quiet-mode
     contract, watcher restart effects, pmfix volatility rationale) if not already covered there.
  3. Comment slimming (zero behavior change): script headers to purpose + reference; inline comments only for
     non-obvious mechanics; deduplicate apparmor.txt/config.yaml mechanism prose against root `KNOWLEDGE.md` §AppArmor;
     audit DOCS.md against translations/en.yaml duplication.
  4. Fix must-fix findings (behavioral): one commit each, lab-verified (`mise run lab hd-idle`), CHANGELOG under 0.1.3.
  5. Final gates: `mise run check`, `mise run lab hd-idle`, dangling-reference sweep (every "see X" resolves), move
     resolved items down.

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

## Code review findings (2026-10-15, v0.1.3)

From the full read-only review (scripts, profile, config, Dockerfile). Must-fix items move up to `## Tasks` when taken
on; the doc/comment items feed the comment-cleanup plan (first task above). Static baseline: shellcheck + bash -n clean
on all six scripts.

### Must-fix

- `KNOWLEDGE.md` §"SG_IO privileges" (~L72): "no capability rules are needed for it" contradicts the shipped profile
  (`capability sys_rawio,` in both profiles - device-verified, the 0.1.3 fix). The sentence conflates two gates: the
  SG_IO ioctl permission (file r/w rules suffice, per the repository-root `KNOWLEDGE.md` §AppArmor) and the kernel's
  `capable(CAP_SYS_RAWIO)` check inside `scsi_cmd_allowed()` (mediated by AppArmor itself - needs the capability rule).
  A future reader following the note would break the `ata` path. Fix the paragraph.
- `pmfix` L31 + `KNOWLEDGE.md` §"Drive-PM treatment": "Known gap (see hd-idle/TODO.md)" dangles - the gap has no TODO
  item. Add it: same-kernel-name reconnects (bridge power-cycles the drive, kernel name unchanged) are invisible to the
  `--since` diff, so the treatment is not re-applied until the next app restart; any detection mechanism must respect
  the redundant-treatment risk (KNOWLEDGE.md).

### Behavior (nice-to-have)

- `hd-idle-watch/run` L75-77: crash/ENOSPC window between the two `mv`s (args first, drives second) leaves the args file
  ahead of the drives file; the `cmp`-equal fast path then never re-syncs drives, so affected drives miss the PM
  treatment until the next real configuration change. Micro-fix: install the drives file first, args last (commit
  point), and consider including the drives file in the per-tick comparison.
- `hd-idle-genargs` L76-95 + L328-344: the "every emitted token must be space-free" defense validates the five scalar
  options but not the emitted per-drive tokens (a hand-edited options.json with whitespace inside `device` or
  `command_type` would produce a broken args line, on the passthrough path silently). One central token check before
  emitting closes it. Schema-validated options cannot hit this; hand-edited options.json can.

### Docs/comments (feed the cleanup)

- `hd-idle-genargs` L9-44: three topics (no-config-file, --quiet contract, CLI-semantics recap) duplicate `KNOWLEDGE.md`
  §1/§2; the --quiet contract has no doc home yet - move it there first, then trim the header to ~8 lines.
- `hd-idle-watch/run` L7-31 + L40-52: near-verbatim duplicate of `KNOWLEDGE.md` §"Automatic drive re-resolution" (which
  is more detailed) - trim to purpose + reference.
- `hd-idle-pmfix` L5-33: duplicates DOCS.md (user-facing why) and `KNOWLEDGE.md` §"Drive-PM treatment" (facts); keep
  only the interface contract (~4 lines) + references.
- `hd-idle/run` L5-16: 73% comment share; trim to ~6 lines (the exec/signal rationale is the only unique bit).
- `config.yaml` L17-29: CAP_SYS_RAWIO block duplicates apparmor.txt + root `KNOWLEDGE.md` §AppArmor - trim to ~3 lines
  plus a pointer (also fixes the awkward L26 wrap).
- `apparmor.txt` L12-17, L21-35, L107-110: war-story duplication with root `KNOWLEDGE.md` §AppArmor (which documents
  capability mediation properly) - keep a short in-place rationale per capability rule + references.
- `DOCS.md` §"Drive power management" duplicates the `en.yaml` `disable_drive_pm` field description (repo rule: DOCS
  must not duplicate option field descriptions) - slim to concept + "see the option" pointer.
- `config.sh` L16-20: the absent-key = default-on rationale (options are user data, NOT refreshed on app update) has no
  doc home - one home in `KNOWLEDGE.md`, referenced elsewhere.
- `hd-idle-genargs` L271-276 vs `hd-idle-watch/run` L71-74: the DRIVES_FILE derivation `case` is duplicated -
  cross-reference comment (behavioral factoring not worth it).
- `hd-idle-genargs` L288-294: document the assumption that `bashio::config` returns one compact JSON object per line for
  list-of-object options (the per-line `bashio::jq` parsing depends on it).
- `apparmor.txt` L87: `/etc/s6-overlay/scripts/* rix` - no such directory exists in this app (template vestige).
- `KNOWLEDGE.md` §"hd-idle -t quirks": no in-app caller remains (the diagnostics build was the only one); add a "kept
  for manual debugging" note or leave knowingly as reference knowledge.

### Verified OK (no action)

shellcheck/bash -n clean; HEALTHCHECK wired (Dockerfile L33-34); parent_disk suffix stripping survives genuinely named
disks (sdp); jq `// empty` passes 0 values through (idle 0, power condition 0); duplicate detection keys on resolved
kernel names; detached-drive passthrough + watcher pickup is coherent; s6 structure matches the user-bundles placement
gotcha (KNOWLEDGE.md); AppArmor sub-profile surface matches the daemon's actual accesses (no args/drives file access,
/data for the activity log, /proc/diskstats); cont-init failure semantics (exit 1 fails the boot loudly); apk pins
DL3018-compliant; pmfix rc handling always surfaces the real rc (misclassification is cosmetic only); smartctl sysfs
rule needed (device probing) and correctly placed in the top profile.

## Resolved

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
