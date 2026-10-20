# Development knowledge (repository-wide)

Non-obvious facts and gotchas that apply to **Home Assistant apps in general** — supervisor behaviors, AppArmor, the HA
base image, testing — collected here for human developers and agents alike, so they don't have to be re-learned per app.
Root causes and design facts specific to one app live in its `<app>/KNOWLEDGE.md`; process and commands for agents live
in `AGENTS.md`; end-user documentation in `<app>/DOCS.md`.

Facts about version-sensitive components (supervisor, AppArmor, HAOS kernels) cite their source (URL + ref) and must be
re-verified before relying on them for new work (see `AGENTS.md`, workflow rules). Supervisor facts below were verified
at ref 2026.10.1 (the pin in `mise.toml`), some also at 2026.09.3 as noted.

## Supervisor: app security rating

`supervisor/apps/utils.py::rating_security` starts at **5** (1–8 clamp) and adjusts:

- AppArmor: disabled −1 / custom profile **+1** (not +2 — easy to miscount)
- Ingress +2; *else* no host network **and no published ports** +2; *else* supervisor-auth-API access +1
- signed +1 — **unreachable**: `AppModel.signed` is a hardcoded `False` stub ("Currently no signing support"; verified
  in 2026.09.3 and 2026.10.1). Images may well be cosign-signed (our CI does keyless signing), but the supervisor cannot
  credit it — treat signing as supply-chain hygiene only.
- High-risk capabilities −1 (a single deduction for the whole branch): `BPF`, `CHECKPOINT_RESTORE`, `DAC_READ_SEARCH`,
  `NET_ADMIN`, `NET_RAW`, `PERFMON`, `SYS_ADMIN`, `SYS_MODULE`, `SYS_PTRACE`, `SYS_RAWIO` — or `kernel_modules: true`
- `hassio_role` manager/admin −1/−2
- host networks −1 (net) / −2 (pid) / −1 (uts + `SYS_ADMIN`)
- docker-API access or `full_access` → **forced to 1** — and `full_access` (with docker API / host PID / host UTS)
  requires protection mode to be disabled by the user, which the `privileged` capability list does not (only those keys
  are gated by protection mode; supervisor `docker/app.py`).

Store listing vs. installed app can differ by the AppArmor +1 — expected, not a device quirk: `AppModel.apparmor`
(supervisor `apps/model.py`, verified 2026.09.3) returns `SECURITY_PROFILE` only when a profile *for this app is already
installed on the host* (`sys_host.apparmor.exists(slug)` checks the supervisor's AppArmor profile store, which
`install_apparmor()` fills during app install/update). A store-listed app has no profile on the host yet →
`SECURITY_DEFAULT` → the branch contributes 0 → the store shows one less than the installed rating. It is *not* related
to AppArmor support on the device — hosts without AppArmor support don't show different ratings; they reject installing
such apps outright (`UnsupportedReason.APPARMOR`).

## Supervisor: option schema quirks

- `match(...)` regexes in `config.yaml` schema fields use voluptuous `Match` (*search* semantics, not fullmatch) —
  always anchor with explicit `^…$`.
- The supervisor's schema-element parser breaks on literal `\t`/`\n` inside YAML double-quoted scalars (they become real
  control characters) — express whitespace classes as `\\s` instead.
- The options DSL (`supervisor/apps/options.py` `RE_SCHEMA_ELEMENT`) has **no uniqueness construct** — list-of-objects
  options are validated entry by entry, cross-entry constraints cannot be expressed (the supervisor itself uses
  `vol.Unique()`, but only in its *own* config schemas, e.g. the `machine` list). Cross-entry guards therefore belong in
  the app's runtime scripts (defense in depth), backed by `match()` regexes on the fields.
- Options are validated **at save time** (schema incl. device-path existence) and delivered to the running app only at
  its next (re)start — option values cannot change under a running app (`supervisor/api/apps.py` options endpoint →
  `app.save_persist()`).
- Installed options are **user data**: config.yaml default changes do NOT reach existing installs (options.json is
  written at first install and at save time only) - new options therefore need absent-key handling in app code
  (`bashio::config '<key>' <default>`), and changing a default is not a behavior change for existing users. Options
  REMOVED from the schema stay in stored options.json and are simply inert: the supervisor logs a one-line warning
  ("Option 'X' does not exist in the schema") on each options read until the user re-saves the options — device-verified
  2026-10-16 (hd-idle 0.1.5 dropping `mode`; the stale key never broke the boot, only warned). A fresh options POST
  replaces the whole set and silently DROPS keys unknown to the schema (device-verified 2026-10-16: full valid set +
  bogus keys → ok, bogus keys not stored; a set missing required keys → rejected); a migration tool therefore filters to
  the target's schema keys to make the drops explicit and reported. `ha apps uninstall` purges the app's OPTIONS in
  every case (device-verified 2026-10-16 with a same-slug uninstall+reinstall: the reinstall had the app's DEFAULT
  options, not the previously stored ones) — the `--remove-config` flag only additionally deletes the app's persistent
  `/data` config folder. Consequently: a reinstall ("fresh install") always runs the app's default options, update and
  rebuild preserve stored options, and a tool that keeps options across an uninstall must read + re-POST them (the
  deploy-registry migration does).

## Supervisor: device access

- Every app container gets the **host `/dev` bind-mounted read-only** (`supervisor/docker/const.py` `MOUNT_DEV`, with
  `read_only_non_recursive=True`), so the udev symlink trees (`/dev/disk/by-id`, `by-uuid`, `by-partlabel`, …) are
  visible to the app on a real device. Plain Docker containers get a tmpfs `/dev` with bare device nodes instead — no
  `/dev/disk` (the lab mirrors it, see below). What actually gates access are Docker `DeviceCgroupRules`, computed per
  app from the sources below.
- **Device-typed option fields** (`device` schema type, optionally `device(subsystem=<udev-subsystem>` — values from
  `hardware/const.py` `UdevSubsystem`, e.g. `block`, `usb`, `tty`) grant the cgroup rules (`c`/`b <major>:<minor> rwm`).
  `AppOptions._collect_device_paths` **recurses into list-of-objects schemas**, so `disks[].device` fields of a list
  option grant access per entry. The UI renders them as a dropdown of `(device.by_id or device.path)` values; the
  subsystem filter is by udev subsystem only (for `block` this still includes partitions and loops).
- **Hotplug**: `docker/app.py::_hardware_events` listens for HARDWARE_NEW_DEVICE and re-grants the cgroup rule when a
  new device matches one of the configured paths against `device.path`, `device.sysfs` or **`device.links`** (the udev
  symlinks — hence by-id paths match after re-plugging even when the kernel letter changed). No app restart needed.
- **System-disk rail**: `hardware/policy.py::allowed_for_access` refuses devices where
  `sys_hardware.disk.is_used_by_system(device)` — at container start and in the hotplug listener alike. Devices the
  system uses cannot be granted to an app, period.
- Validation timing: the `device` type validates existence **at options save time** (`write_options` → `get_by_path`) —
  saving a config while the device is detached fails with a clear message. At app **startup** the validation result is
  suppressed (`App.devices` does `with suppress(vol.Invalid)`); a detached device at boot does not prevent the app from
  starting.

## Supervisor: store slugs (in-app documentation links)

- Installing an app **from an app repository** gives it the installed slug `<hash>_<slug>` where hash = the first 8 hex
  of `sha1(lowercased_repository_url)` (`supervisor/store/utils.py` `get_hash_from_repository`; verified numerically
  2026-10: `sha1("https://github.com/salim-b/home-assistant-apps-salim")[:8]` = `f8b2d53d`). Local test installs under
  `/local_apps/` get `local_<slug>`.
- In-app links (`README.md`/`DOCS.md` `/config/app/<hash>_<slug>/...`) must use the hashed form to work for the
  repository install (the normal user case); they are dead links for local test installs — expected, those are dev-only.

## AppArmor: mediation gotchas and profile mechanics

Device-verified 2026-10 on HAOS 18.3 / OS Agent 1.14 / AppArmor 3.1.7.

- **Capabilities are mediated**: a profile without explicit `capability …` rules denies all capabilities it is asked
  about at the LSM hook — including the `capable(CAP_SYS_ADMIN)` check inside the mount(2) syscall path, even when the
  `mount …` rule itself grants the mount. Docker's default profile carries a blanket `capability,`, so plain Docker
  containers never hit this. List every capability the binaries need. Sub-profile subtlety: capabilities a binary needs
  *for its own self-management* also need rules — `prctl(PR_CAPBSET_DROP)` and `capset(2)` require `CAP_SETPCAP` (found
  via nfsdcld, which prunes its whole bounding set at startup: without the rule it exits in a restart loop, "Unable to
  prune capability 0 from bounding set: Operation not permitted"). The lab cannot catch such issues — it has no AppArmor
  enforcement.
- **Errno forensics replace missing denial logs**: HAOS produces *no* AppArmor audit messages in the host journal
  (`ha host logs` carries kernel lines but nothing apparmor/DENIED — no usable audit plumbing), so complain-mode
  iteration is impossible; enforcement bugs must be diagnosed from boot progress. Useful signals:
  - busybox `mount` prints `mounting SRC on DST failed: Permission denied` for **EACCES** (`%m`; observed for a
    *mount-rule* denial) and `permission denied (are you root?)` for **EPERM** (dedicated abort path; observed for a
    *capability* denial).
  - In-container ground truth is file-rule-accessible: `cat /proc/self/attr/current` (profile + mode) and
    `grep CapEff /proc/self/status`.
- **Mount rule grammar** (parser `apparmor.d.pod`): the mount-flags conditional is `options=` (there is no `flags=`);
  `fstype=` matching only applies to *new* mounts — not bind/remount — so `mount --bind` rules are conditioned on
  `options=(bind)` instead. Mount sources are matched as passed: busybox passes the device string for pseudo-filesystems
  (e.g. `nfsd`, `sunrpc`, not a path).
- **Ioctls**: AppArmor mediates ioctls only via the file's r/w permission. Per-command ioctl mediation does not exist in
  any released AppArmor (re-verified 2026-10 against the AppArmor 4.0 release notes and the 6.17-era upstream pulls: new
  mediation covers POSIX mqueue, user namespaces, io_uring and AF_UNIX; fine-grained inet/inet6 is still
  work-in-progress
  - ioctls are not on the roadmap) — e.g. `SG_IO` on disk nodes is covered by `/dev/sd* rwk`-style file rules, and no
    capability rules are needed for the ioctl itself (kernel-side `capable()` checks inside command paths are a separate
    gate — capabilities are mediated, see above).
- **Network mediation is opt-in per class**: a profile without any `network` rules has networking *entirely unmediated*
  (everything allowed) — "no rules" is not "no networking". Adding any network rule (allow or deny) enables mediation,
  and everything not matched by an allow rule is then denied; `deny network,` denies a class outright. The parser
  (5.0.2) does not support domain/type tuples — write individual rules (`network inet stream`, `network inet dgram`,
  `network inet6 …`, `network netlink raw`, …).
- **File-rule tightening is impractical**: without audit logs there is no way to iterate file rules safely, so a `file,`
  blanket is the upstream HA convention (docs template, dnsmasq, this repo's apps). The profile's confinement value sits
  in the non-file classes (network, capability, mount), which Docker's default profile would otherwise grant broadly.
- **Supervisor profile mechanics**: the profile is installed from the app folder's `apparmor.txt` on install/update and
  **renamed to the installed slug** (`local_<slug>` for repo-folder installs, `<hash>_<slug>` when installed from a
  repository) — the declared profile name is otherwise arbitrary. Requirements: exactly one top-level (non-indented)
  `profile` declaration (the supervisor's profile-name regex rejects more than one); nested sub-profiles must be
  indented so `^profile` doesn't match them. Sources: supervisor `utils/apparmor.py`, `apps/app.py`.
- **Profile changes need a `config.yaml` version bump**: the supervisor re-installs (and reloads) profiles on app
  *update*, but `App.rebuild()` does **not** call `install_apparmor()` — a no-bump change of `apparmor.txt` is silently
  not applied on the device.
- **Kernel module autoload via mount is kernel-context, outside the label**: mounting a filesystem type whose module is
  not loaded makes the kernel `request_module(...)` in kernel context (`call_usermodehelper`) — outside the container's
  AppArmor label and capability set. Consequently mounting e.g. `nfsd` needs no app-level modprobe, no `sys_module`
  capability, no `/lib/modules` access and no `kernel_modules: true` (verified on HAOS 18.3 / kernel 6.18.52-haos by
  rebooting with the module unloaded; the `kernel_modules` option only maps `/lib/modules` read-only and grants
  `SYS_MODULE` — both inert under a denying profile).

## apk package version policy

**Official apps' practice** (home-assistant/addons, verified 2026-10): apk packages **float** (`dnsmasq`, `samba`,
`mariadb`, `vlc`: bare `apk add --no-cache <pkg>`), while version-sensitive *cores* are pinned explicitly via
`build.yaml` ARGs and used in build/pip (`mosquitto` 2.1.2, `letsencrypt`'s certbot/cryptography stack, `whisper`'s pip
stack). Base images float within their branch tag. Floating apk packages means their released images get newer package
content on rebuilds without a version bump (fresh installs drift; existing installs keep the old digest until the next
versioned release).

**Our policy** splits by coupling:

- **Pin** (full `pkgver-pkgrel`, e.g. `hd-idle=1.22-r8`) when the app's runtime logic encodes the package's interface:
  hd-idle's arg generator (`hd-idle/rootfs/usr/bin/hd-idle-genargs`) relies on hd-idle's CLI semantics, so every package
  change must be a deliberate app change - one app release (pin + `config.yaml` version + changelog) per package
  version.

- **Float** when chasing pkgrel rebuilds adds churn without user value: nfs-server's `nfs-utils` (multi-binary ecosystem
  whose kernel-consistency matters more than the exact userspace version).

- Both are enforced/verified by `validate.py` (`validate_apk_pins`): it extracts the BUILD_FROM default branch and the
  apk pins from each app's Dockerfile and compares them against the Alpine **binary indexes** (dl-cdn APKINDEX, x86_64 +
  aarch64, community then main, cached 24 h). A mismatch fails with the release workflow — turning an Alpine-side
  repoint into a guided release instead of silent image drift. It runs in `mise run check`, and the CI lint workflow's
  **daily cron** flags drift within a day; until the pin is chased, the *next* build would break anyway (the index
  serves only the current pkgrel, old ones disappear).

- **Renovate opens the update PR — including the config.yaml version bump** (verified with a local
  `npx renovate@latest --platform=local --dry-run=full` run: extraction + APKINDEX lookup + rule resolution; the branch
  edit itself only happens in a real run — safe by construction, see below): the Dockerfile manager extracts
  `apk add pkg=version` pins into the `apk` datasource, and the `.github/renovate.json` apk packageRule supplies the
  `registryUrls` (dl-cdn APKINDEX URLs, branch + arch pinned) without which Renovate silently skips the pins
  (`skipReason: unknown-registry` — it cannot infer the Alpine branch from the base-image ARG). The rule also carries a
  `bumpVersions` entry (experimental Renovate feature): the app's `config.yaml` version is patch-bumped in the same PR
  (`{{packageFileDir}}/config.{yaml,yml}`). The matchString anchors at line start via `(?:^|\n)` emulation: Renovate
  compiles matchStrings without the `m` flag (`bump-versions.ts` runs `regEx(templated)`), so a plain `^` would bind to
  file offset 0 (config.yaml's first line is a comment → zero matches → silent no-bump), and an unanchored match would
  let a future comment containing `version: "..."` hijack the bump (both verified against our config with node); only
  the FIRST match per file is bumped (single `exec`, no `g` flag). The version-guard workflow still passes on the
  Renovate PR as opened. What Renovate cannot do on the hosted app: run post-upgrade tasks — `postUpgradeTasks.commands`
  need `allowedPostUpgradeCommands`, a **self-hosted-only** option — so the changelog entry is filled post-merge by the
  CI changelog job instead (see the release-automation bullet below). The rule's registryUrls branch value must be
  updated together with the Dockerfile's `BUILD_FROM` default on a base-image bump; the validate.py drift check derives
  the branch dynamically and remains the config-independent net (if `bumpVersions` ever misbehaves, version-guard fails
  the PR loudly — no silent drift). Floating apk packages (nfs-utils) are skipped (`unspecified-version`), as intended.

- **Release automation (since 2026-10-18)**: the guided release above is followed up automatically end-to-end. Merge
  behavior by update type (`.github/renovate.json` chained apk rules): pkgrel-only bumps (`1.22-r7` -> `1.22-r8` — the
  apk datasource's `apk` versioning classifies them as `patch`) **automerge once CI is green**
  (`automergeStrategy: rebase`, same linear-history rationale as the supervisor-pin rule), while pkgver bumps (upstream
  version changes, `minor`/`major`) get the `needs-review` label and stay manual — CLI semantics may change, cf.
  `hd-idle-genargs`. Top-level `platformAutomerge: false` keeps merges on Renovate's own path (no branch protection and
  "Allow auto-merge" are off today; the explicit setting prevents a later repo-toggle enablement from merging before CI
  finishes). The changelog section is filled post-merge by the apk-bump workflow's changelog job (a merged
  `renovate[bot]` PR labeled `apk_pin` — covering Renovate automerges and manually merged pkgver PRs alike): it parses
  the full Dockerfile contents at the PR's base and head SHAs (apk pins old -> new, robust against patch hunk boundary
  truncation for future apps with long apk blocks) and the `config.{yaml,yml}` version bump, and runs the
  `apk-changelog` mise task (`.mise/tasks/apk-changelog.py`, shared with local runs; flags declared `required=true` in
  the usage spec — mise enforces them natively, no duplicated validation) to insert the templated `## <version>` section
  — idempotent, a pre-written section is never touched (a PR touching several pins of the same app records only the
  first; Renovate opens one PR per package anyway). The resulting docs-only commit is pushed with the `GITHUB_TOKEN`,
  whose push-event workflow suppression is intended: CHANGELOG.md is excluded by version-guard and the image is
  byte-identical, so no rebuild is needed. The same workflow's nudge job (daily 01:30 UTC, also `workflow_dispatch`-able
  with a `dry_run` boolean input to log would-be comments without posting them; it accepts both `config.yaml` and
  `config.yml`) handles the per-arch repush skew documented in the gotchas below: an early bump PR legitimately stays
  red until the lagging arch's index catches up; once ALL of the app's arch indexes serve the new pin, the job comments
  `@renovate rebase` (capped at 3 per PR) — a rebase creates fresh check runs, while re-running failed check runs can
  still count as red in Renovate's automerge evaluation; while an arch still lags it does nothing and the daily lint
  cron remains the drift alarm. Missed image publishes self-heal via the publish-reconcile workflow (daily 03:15 UTC):
  it checks GHCR for every app's version tags (per-arch `ghcr.io/salim-b/<arch>-app-<name>:<version>` plus the
  multi-arch manifest) via anonymous `docker buildx imagetools inspect` probes with the runner-preinstalled buildx
  (copacetic-style classification: not-found-class errors mean a missing tag, any other failure is retried with
  exponential backoff and then fails the run red - so transient outages neither dispatch nor silently pass) and
  dispatches `build-app.yaml` (now also `workflow_dispatch`-able; publish=true, ref=main) on a genuine miss —
  idempotent, a healthy registry is a green no-op. Tag existence only: stale-content tags are not detected (content
  drift is version-guard's/validate's domain). The tooling landscape was researched 2026-10-18: no OSS tooling exists
  for apk-pin bumping with arch gates — Renovate's native support plus a hand-rolled gate is the state of the art
  (linuxserver.io precedent: their scheduled external-trigger workflows enforce the same all-arches condition before
  rebuilding, cf. linuxserver/docker-wireguard `.github/workflows/external_trigger.yml`). Dependabot cannot bump apk
  pins at all (dependabot-core#2129, open since 2019), updatecli has no apk/APKINDEX plugin, and Chainguard's
  `melange bump` rewrites melange build YAML, not Dockerfiles.

Version-sensitive gotchas learned while implementing:

- **The aports source branch can outrun the binary index**: verified 2026-10 — the `3.24-stable` APKBUILD said
  `pkgrel=8` while both arches' APKINDEX still served `1.22-r7`. A pin must be compared against what `apk add` actually
  resolves (the APKINDEX), not the APKBUILD source.
- The GitHub aports mirror (alpinelinux/aports) names stable branches `3.24-stable` (no `v` prefix, unlike the GitLab
  branches); raw fetches there are for source inspection only — version checks use dl-cdn.
- **The binary-index repush is per-arch and can skew between the arches**: verified 2026-10-16 — after the Go 1.26.5
  rebuild above, the v3.24 aarch64 APKINDEX began serving `1.22-r8` (package built 2026-10-14) while x86_64 still served
  `1.22-r7`; the daily cron flagged the drift the same day. In such a window the arches' indexes disagree, so *no* pin
  passes `validate_apk_pins` (strict per-arch equality). Bump to the newest index version anyway: the repointed arch no
  longer serves the old package, so a cold-cache build of the stale pin breaks there (the builder's layer cache can mask
  this for a while), while the lagging arch's mismatch is transient and self-heals when its repush lands — pinning the
  older version instead would leave both arches failing once the lagging arch repushes. During the window, a red check
  on the lagging arch is accurate signal: that arch's cold-cache builds cannot yet resolve the new pin.

## HA base image: shell gotchas

- **`echo`/`printf` emit a single `writev(2)`**: the base image's bash (5.3.9) implements the output of its `echo` and
  `printf` builtins as one `writev(2)` call, with the text and the trailing newline as separate iovecs. Kernel files
  that only implement the old-style single-buffer `.write` and no `.write_iter` (many procfs/sysfs transaction files,
  e.g. `/proc/fs/nfsd/*`) reject `writev(2)` with `EINVAL` on modern kernels — producing a misleading
  `write error: Invalid argument` that is about the syscall *shape*, not the written content. Callers that do a single
  `write(2)` (busybox `echo`, `cat`, many C daemons' own writes) succeed. Workaround when a direct write is unavoidable:
  stage the string in a regular file (e.g. on tmpfs) and `cat` it into the target. (Which files this bites in a given
  app: see the app's `KNOWLEDGE.md`.)
- **Failed redirections bypass the command's `2>/dev/null`**: a failed redirection is diagnosed by the shell itself,
  *before* the command's own redirections are in effect — `echo x > /some/ro/path 2>/dev/null` still prints
  `sh: can't create /some/ro/path: …`. To suppress (or capture) the shell's diagnostic, run the attempt in a subshell:
  `out=$( (echo x > /some/ro/path) 2>&1 )` captures message *and* exit code.
- **`with-contenv` wipes the inherited environment unless `S6_KEEP_ENV=1`**: the s6-overlay shebang helper runs
  `emptyenv -p` and then imports only `/run/s6/container_environment` (the variables the supervisor/s6 boot provides).
  Anything exported by a calling shell or `docker run -e` is erased — unless `S6_KEEP_ENV=1` is set, which makes
  `with-contenv` pass the inherited environment through untouched (production s6-rc boots are unaffected: there the env
  arrives via `container_environment` either way).
- **Stubbing `bashio::config` in bare-container script tests**: `bashio::config` fetches the app options from the
  Supervisor API (`bashio::app.config` → `GET /addons/self/options/config`), backed by a file cache — it never reads
  `/data/options.json`. Seeding `${CACHE_DIR}/addons.self.options.config.cache` (env override `CACHE_DIR`; the key is
  fixed, `bashio::cache` appends `.cache` and validates `^[A-Za-z0-9._-]+$`) with the crafted options JSON stubs the API
  exactly (the cache stores the raw response). Requires the `S6_KEEP_ENV=1` gotcha above, since `CACHE_DIR` is an
  inherited variable. (Used for the hd-idle per-drive-PM decision-matrix tests, 2026-10.)

## s6-overlay: user bundles live OUTSIDE s6-rc.d

Adding a service to a bundle (e.g. the default `user` bundle) is done via
`/etc/s6-overlay/user-bundles.d/<bundle>/contents.d/<service>` — a path that must NOT be under `s6-rc.d/`. A stray
directory under `s6-rc.d/` (e.g. `s6-rc.d/user-bundles.d/`) is scanned by `s6-rc-compile` as a *service source
directory* and fails the whole boot with
`fatal: unable to read /etc/s6-overlay/s6-rc.d/user-bundles.d/type: No such file or directory` — the container
crash-loops at preinit while the supervisor still reports the app state as "started" (device-verified 2026-10-15). The
symptom is invisible to health checks (the container never reaches them), so any change under
`rootfs/etc/s6-overlay/s6-rc.d/` or `user-bundles.d/` must be lab-booted (`mise run lab <app>`) before deploy.

**User-bundle services must declare a `dependencies.d/base` dependency** (empty *file*, per s6-overlay's MOVING-TO-V3
guidance; see the nfs-server app's services): s6-rc brings the user bundle up in dependency order, and without a
dependency on the built-in `base` bundle a longrun can start BEFORE `legacy-cont-init` (the compat oneshot running
`/etc/cont-init.d/*`) has completed — device-verified 2026-10-15: the hd-idle app's daemon started before its cont-init
phase wrote the generated configuration and crashed twice
(`./run: line 9: /etc/hd-idle.args: No such file or directory`) until s6-supervise's restart loop finally started it;
the lab missed it because its checks only grepped positive markers that also exist after the self-healing restart. Empty
dependency *directories* are equally broken in a subtler way: git does not track them, so they silently vanish from the
image.

## Testing: hardware-behavior checks in the lab

The lab boots app containers `--privileged` **on the lab host**, so host-side hardware state interacts with tests:

- **Host-side interference sweep**: OS-level power-management mechanisms can skew hardware tests (for disk spindown:
  udisks2 stored drive settings — re-applied on every hotplug; `/etc/hdparm.conf` directives; TLP `DISK_*`; smartd;
  powertop auto-tune; the per-device runtime-PM `power/control` state) — and the inverse, desktop IO on mounted devices
  waking them. Mainstream distros ship none of these active by default; they are user-configured. App hooks doing
  hardware tests should run a read-only preflight sweep and warn (see `hd-idle`'s lab hook for the pattern).
- **Assert event-based, never "stays in state for N minutes"**: hardware state can legitimately change (a drive woken by
  unrelated IO is correct system behavior) — assert the event/transition (log lines, state probes right after a
  triggered command) rather than persistence of a state.
- **Probe tools can themselves disturb the state**: verify your probe is side-effect-free (e.g. `hdparm -C` both races
  spin-down windows and can *wake* USB-attached drives; `smartctl -n standby` is designed not to).
  Device/bridge-specific findings live in the apps' `KNOWLEDGE.md`.
- **Plain Docker vs. HAOS `/dev`**: see the device-access section — when an app's behavior depends on the udev symlink
  trees, the lab hook must mirror the supervisor's read-only host-`/dev` bind (e.g. `-v /dev/disk:/dev/disk:ro`).

## YAML linting: ryl (replaced yamllint)

YAML is linted by [ryl](https://ryl-docs.pages.dev/) — the hk `ryl` step with config `.ryl.toml`, pinned as
`aqua:owenlamont/ryl` in `mise.toml`. Facts that outlive the swap:

- **ryl parses YAML 1.2; yamllint defaulted to 1.1** (ryl docs, [YAML version
  compatibility](https://ryl-docs.pages.dev/yaml-version/), observed on ryl 0.26.0): bareword booleans
  (`yes`/`no`/`on`/`off`, any case) are plain strings to ryl and leading-zero integers like `0755` are decimal — while
  YAML 1.1 parsers (PyYAML and kin) still coerce both. Don't predict what a parser will load from ryl's lint view.
- **Warnings fail via `--strict`**: the hk step runs `ryl check --strict`, so warning-level rules (line-length,
  comments, document-start, truthy — see `.ryl.toml`) fail the gate like yamllint's `--strict` did (warning-only runs
  exit `2` under `--strict`, errors `1`).
- **The step is deliberately not hk's `Builtins.ryl`**: the builtin selects files by hk file typing, omits `--strict`
  and carries an auto-fix (`--fix`) step; this repo keeps yamllint's glob selection (`**/*.yml`, `**/*.yaml`) and stays
  check-only.
- **`line-length` ignores comments by default** (yamllint parity): long comment lines don't fail the gate — the 140
  limit bites YAML scalars only.
- **Config is TOML with `[lint.rules]`**: `[rules]` still parses but is deprecated as of ryl 0.26 (the built-in
  migrator, `ryl --migrate-configs`, emits the `[lint.rules]` form), and a rule with an option table must not also
  appear as a `"<name> = "enable"` string in the same table — TOML duplicate key, and ryl exits `2` loudly instead of
  linting.
