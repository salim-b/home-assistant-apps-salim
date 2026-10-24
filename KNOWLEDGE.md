# Development knowledge (repository-wide)

Non-obvious facts and gotchas that apply to **Home Assistant apps in general** — supervisor behaviors, AppArmor, the HA
base image, HAOS specifics — for human developers and agents alike. Procedures (how to do things step by step) live in
the skills under `.agents/skills/` (index in `AGENTS.md`); app-specific facts in `<app>/KNOWLEDGE.md`; open work items
in `TODO.md`.

Facts about version-sensitive components (supervisor, AppArmor, HAOS kernels) cite their source (URL plus ref) and must
be re-verified before relying on them for new work (skill `ha-app-workflow`). Supervisor facts below were verified at
refs 2026.09.3–2026.10.2 (Renovate keeps the `mise.toml` `supervisor_ref` pin fresh — re-check against the current pin
when relying on them), some at specific refs as noted.

## Supervisor: app security rating

`supervisor/apps/utils.py::rating_security` starts at **5** (1–8 clamp) and adjusts:

- AppArmor: disabled −1 / custom profile **+1** (not +2 — easy to miscount)
- Ingress +2; *else* no host network **and no published ports** +2; *else* supervisor-auth-API access +1
- signed +1 — **unreachable**: `AppModel.signed` is a hardcoded `False` stub ("Currently no signing support"; supervisor
  2026.09.3 and 2026.10.1). Images may well be cosign-signed (our CI does keyless signing), but the supervisor cannot
  credit it — treat signing as supply-chain hygiene only.
- High-risk capabilities −1 (a single deduction for the whole branch): `BPF`, `CHECKPOINT_RESTORE`, `DAC_READ_SEARCH`,
  `NET_ADMIN`, `NET_RAW`, `PERFMON`, `SYS_ADMIN`, `SYS_MODULE`, `SYS_PTRACE`, `SYS_RAWIO` — or `kernel_modules: true`
- `hassio_role` manager/admin −1/−2
- host networks −1 (net) / −2 (pid) / −1 (uts + `SYS_ADMIN`)
- docker-API access or `full_access` → **forced to 1** — and `full_access` (with docker API / host PID / host UTS)
  requires protection mode to be disabled by the user, which the `privileged` capability list does not (only those keys
  are gated by protection mode; supervisor `docker/app.py`).

Store listing vs. installed app can differ by the AppArmor +1 — expected, not a device quirk: `AppModel.apparmor`
(supervisor `apps/model.py`) returns `SECURITY_PROFILE` only when a profile *for this app is already installed on the
host* (`sys_host.apparmor.exists(slug)` checks the supervisor's AppArmor profile store, filled during app
install/update). A store-listed app has no profile on the host yet → `SECURITY_DEFAULT` → the branch contributes 0 → the
store shows one less than the installed rating. Hosts without AppArmor support don't show different ratings; they reject
installing such apps outright (`UnsupportedReason.APPARMOR`).

- App containers run **without seccomp** (`DockerInterface.security_opt`: "Disable Seccomp / We don't support it
  official and it causes problems on some types of host systems", supervisor `docker/interface.py` 2026.10.2) - so no
  `no_new_privs` from a seccomp policy. The Docker default capability set is only trimmed by opt-in feature flags:
  `APP_DROP_NET_RAW` (NET_RAW) and `APP_REDUCED_CAPABILITIES` (`REDUCED_CAPABILITIES_DROP` = AUDIT_WRITE, MKNOD, SETFCAP -
  `docker/const.py`). Capabilities outside those lists (`setuid`/`setgid`/`setpcap`/`net_bind_service` among them)
  survive every flag - apps relying on them need no `privileged:` entries.

## Supervisor: option schema quirks

- `match(...)` regexes in `config.yaml` schema fields use voluptuous `Match` (*search* semantics, not fullmatch) —
  always anchor with explicit `^…$`.
- The supervisor's schema-element parser breaks on literal `\t`/`\n` inside YAML double-quoted scalars (they become real
  control characters) — express whitespace classes as `\\s` instead.
- The options DSL (`supervisor/apps/options.py` `RE_SCHEMA_ELEMENT`) has **no uniqueness construct** — list-of-objects
  options are validated entry by entry, cross-entry constraints cannot be expressed (the supervisor itself uses
  `vol.Unique()`, but only in its *own* config schemas). Cross-entry guards therefore belong in the app's runtime
  scripts (defense in depth), backed by `match()` regexes on the fields.
- There is **no single-value select matcher**: `list(a|b|c)` validates with `vol.In` (a single value out of the
  alternatives) and the UI renders it as a single-value dropdown — also inside list-of-object items
  (`supervisor/apps/options.py` at 2026.10.2; frontend `supervisor-app-config.ts` passes the UI schema's non-`multiple`
  select through as-is). Dropdown values get no labels: the translation schema (`SCHEMA_TRANSLATION_CONFIGURATION`)
  supports only `name`/`description`/`fields`, so the UI shows the raw values. The UI schema has **no conditional
  visibility** — a field cannot be shown only when another field has a particular value; use the field description
  instead ("ignored unless …").
- Empty optional fields inside list-of-object items are save-safe: the frontend emits `undefined` for cleared
  number/select inputs and skips untouched optional fields entirely (`computeInitialHaFormData` does nothing for
  non-required fields), and JSON serialization drops those keys; cleared *text* inputs emit `""`, which passes `str`
  validation — app code should treat `""` like unset.
- Options are validated **at save time** (schema incl. device-path existence) and delivered to the running app only at
  its next (re)start — option values cannot change under a running app (`supervisor/api/apps.py` options endpoint →
  `app.save_persist()`).
- Installed options are **user data**: `config.yaml` default changes do NOT reach existing installs (`options.json` is
  written at first install and at save time only) — new options need absent-key handling in app code
  (`bashio::config '<key>' <default>`), and changing a default is not a behavior change for existing users.
- Options REMOVED from the schema stay in stored `options.json` and are simply inert: the supervisor logs a one-line
  warning ("Option 'X' does not exist in the schema") on each options read until the user re-saves — device-verified
  2026-10-16 (hd-idle 0.1.5 dropping `mode`; the stale key never broke the boot, only warned).
- A fresh options POST replaces the whole set and silently DROPS keys unknown to the schema (a set missing required keys
  is rejected) — a migration tool therefore filters to the target's schema keys to make the drops explicit and reported.
- `ha apps uninstall` purges the app's OPTIONS in every case (device-verified 2026-10-16 with a same-slug
  uninstall+reinstall: the reinstall had the app's DEFAULT options, not the previously stored ones) — the
  `--remove-config` flag only additionally deletes the app's persistent `/data` config folder. Consequently: a reinstall
  ("fresh install") always runs the app's default options, update and rebuild preserve stored options, and a tool that
  keeps options across an uninstall must read + re-POST them (the deploy-registry migration does; task semantics: skill
  `ha-app-device-testing`).

## Supervisor: device access

- Every app container gets the **host `/dev` bind-mounted read-only** (`supervisor/docker/const.py` `MOUNT_DEV`, with
  `read_only_non_recursive=True`), so the udev symlink trees (`/dev/disk/by-id`, `by-uuid`, `by-partlabel`, …) are
  visible to the app on a real device. Plain Docker containers get a tmpfs `/dev` with bare device nodes instead — no
  `/dev/disk` (the lab mirrors it; skill `ha-app-lab-testing`). What actually gates access are Docker
  `DeviceCgroupRules`, computed per app from the sources below.
- **Device-typed option fields** (`device` schema type, optionally `device(subsystem=<udev-subsystem>` — values from
  `hardware/const.py` `UdevSubsystem`, e.g. `block`, `usb`, `tty`) grant the cgroup rules (`c`/`b <major>:<minor> rwm`).
  `AppOptions._collect_device_paths` **recurses into list-of-objects schemas**, so `disks[].device` fields of a list
  option grant access per entry. The UI renders them as a dropdown of `(device.by_id or device.path)` values; the option
  schema's filter regex accepts `subsystem=<subsystem>` only (`apps/options.py`), so filtering is by udev subsystem only
  — for `block` partitions leak into the dropdown (by-id `...-partN` links), while loop devices are already hidden by
  `_RE_HIDE_SYSFS` (`hardware/helper.py`: `/sys/devices/virtual/block/*`; supervisor main @ b8d32f2, 2026-10-28; the
  frontend renders the supervisor-provided options verbatim).
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

## Supervisor: health events and the app watchdog

- The supervisor does not poll Docker HEALTHCHECK status — it listens to Docker events: `docker/monitor.py` translates
  `health_status: healthy|unhealthy` into `DOCKER_CONTAINER_STATE_CHANGE` bus events (the exit code is populated only
  for `die` transitions; supervisor 2026.10.2).
- The restart decision is per-component: each component registers its own `watchdog_container` on that bus event — for
  apps it is `apps/app.py::watchdog_container`, which restarts on FAILED/STOPPED/UNHEALTHY only when the app's
  `watchdog` option is enabled and the container was not manually stopped.
- Consequence for app design: s6 supervises processes *inside* the container, but only a HEALTHCHECK turns a
  persistently wedged or crash-looping daemon into a container-level signal the supervisor can act on (hd-idle relies on
  exactly this: hd-idle/KNOWLEDGE.md §"Daemon failure semantics").

## Supervisor: store slugs (in-app documentation links)

- Installing an app **from an app repository** gives it the installed slug `<hash>_<slug>` where hash = the first 8 hex
  of `sha1(lowercased_repository_url)` (`supervisor/store/utils.py` `get_hash_from_repository`; verified numerically
  2026-10: `sha1("https://github.com/salim-b/home-assistant-apps-salim")[:8]` = `f8b2d53d`). Local test installs under
  `/local_apps/` get `local_<slug>`.
- In-app links (`README.md`/`DOCS.md` `/config/app/<hash>_<slug>/...`) must use the hashed form to work for the
  repository install (the normal user case); they are dead links for local test installs — expected, those are dev-only.

## AppArmor: mediation and profile mechanics

Device-verified 2026-10 on HAOS 18.3 / OS Agent 1.14 / AppArmor 3.1.7. Authoring and denial-forensics procedures: skill
`ha-app-apparmor`.

- **Capabilities are mediated**: a profile without explicit `capability …` rules denies all capabilities it is asked
  about at the LSM hook — including the `capable(CAP_SYS_ADMIN)` check inside the mount(2) syscall path, even when the
  `mount …` rule itself grants the mount. Docker's default profile carries a blanket `capability,`, so plain Docker
  containers never hit this. List every capability the binaries need. Sub-profile subtlety: capabilities a binary needs
  *for its own self-management* also need rules — `prctl(PR_CAPBSET_DROP)` and `capset(2)` require `CAP_SETPCAP`
  (without the rule, a bounding-set-pruning daemon exits in a restart loop).
- **Errno forensics replace missing denial logs**: HAOS produces *no* AppArmor audit messages in the host journal
  (`ha host logs` carries kernel lines but nothing apparmor/DENIED — no usable audit plumbing). Useful signals: busybox
  `mount` prints `mounting SRC on DST failed: Permission denied` for **EACCES** (mount-rule denial) and
  `permission denied (are you root?)` for **EPERM** (capability denial); in-container ground truth is
  file-rule-accessible: `cat /proc/self/attr/current` (profile plus mode) and `grep CapEff /proc/self/status`.
- **Mount rule grammar** (parser `apparmor.d.pod`): the mount-flags conditional is `options=` (there is no `flags=`);
  `fstype=` matching only applies to *new* mounts — not bind/remount — so `mount --bind` rules are conditioned on
  `options=(bind)` instead. Mount sources are matched as passed: busybox passes the device string for pseudo-filesystems
  (e.g. `nfsd`, `sunrpc`, not a path).
- **Ioctls**: AppArmor mediates ioctls only via the file's r/w permission. Per-command ioctl mediation does not exist in
  any released AppArmor (re-verified 2026-10 against the AppArmor 4.0 release notes and the 6.17-era upstream pulls: new
  mediation covers POSIX mqueue, user namespaces, io_uring and AF_UNIX; fine-grained inet/inet6 is still
  work-in-progress) — e.g. `SG_IO` on disk nodes is covered by `/dev/sd* rwk`-style file rules, and no capability rules
  are needed for the ioctl itself (kernel-side `capable()` checks inside command paths are a separate gate —
  capabilities are mediated, see above).
- **Network mediation is opt-in per class**: a profile without any `network` rules has networking *entirely unmediated*
  (everything allowed) — "no rules" is not "no networking". Adding any network rule (allow or deny) enables mediation,
  and everything not matched by an allow rule is then denied; `deny network,` denies a class outright. The parser
  (5.0.2) does not support domain/type tuples — write individual rules (`network inet stream`, `network inet dgram`,
  `network inet6 …`, `network netlink raw`, …).
- **File-rule tightening is impractical**: without audit logs there is no way to iterate file rules safely, so a `file,`
  blanket is the upstream HA convention (docs template, dnsmasq, this repo's apps). The profile's confinement value sits
  in the non-file classes (network, capability, mount), which Docker's default profile would otherwise grant broadly. A
  missed rule in a tightened file set fails silently and undiagnosably on the device, while the marginal gain is near
  zero — the real boundaries are the supervisor's cgroup device rules plus the non-file classes. A strace-derived access
  inventory is not a safe basis for tightening either: the lab cannot exercise device-only paths, and AppArmor mediates
  more than strace shows (directory reads behind globs, mmap exec bits, locks, disconnected/deleted-file mediation).
  Revisit only if HAOS ever ships usable AppArmor audit plumbing.
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
- **Never-root low-port daemons: ambient capabilities, not file capabilities.** File capabilities on a binary are
  exec-acquired and inert under `no_new_privs` (which Docker sets whenever its seccomp policy applies - not on HAOS, but
  don't rely on that). The robust pattern is util-linux `setpriv` in the s6 launcher (the busybox `setpriv` applet has
  no uid options; the apk replaces it at `/bin/setpriv`):
  `setpriv --no-new-privs --reuid 65534 --regid 65534 --clear-groups --inh-caps=+net_bind_service --ambient-caps=+net_bind_service <daemon>` -
  ambient capabilities are runtime prctl state (kernel >= 4.3), survive exec even under `no_new_privs`, and leave the
  daemon holding exactly the one capability (verified: `CapEff`/`CapPrm`/`CapAmb` = `0000000000000400`). The profile
  then grants `setuid`/`setgid`/`setpcap` for the launcher's syscalls and `net_bind_service` for the bind.

## apk package version policy

**Official apps' practice** (home-assistant/addons, verified 2026-10): apk packages **float** (`dnsmasq`, `samba`,
`mariadb`, `vlc`: bare `apk add --no-cache <pkg>`), while version-sensitive *cores* are pinned explicitly via
`build.yaml` ARGs (mosquitto, letsencrypt's certbot/cryptography stack, whisper's pip stack). Floating apk packages
means released images get newer package content on rebuilds without a version bump; existing installs keep the old
digest until the next versioned release.

**Our policy** splits by coupling:

- **Pin** (full `pkgver-pkgrel`, e.g. `hd-idle=1.22-r8`, `nfs-utils=2.6.4-r6`) when the app's runtime logic encodes the
  package's interface (hd-idle's arg generator relies on hd-idle's CLI semantics; nfs-server's scripts rely on
  exportfs's export-table/fsid semantics, the rpc.nfsd CLI and nfsdcld's client-tracking store format): every package
  change becomes a deliberate app release (pin plus `config.yaml` version plus changelog). The release automation
  (Renovate apk datasource, pkgrel-only automerge, post-merge changelog job) keeps the release cost of pinning near zero
  even for frequently-rebuilt packages.
- **Float** when the package's interface is not encoded in the app's runtime logic (a generic tool the app runs but
  never inspects): chasing pkgrel rebuilds would add version-bump churn without user value.

Enforcement: `validate.py` (`validate_apk_pins`) extracts the BUILD_FROM default branch and the apk pins from each app's
Dockerfile and compares them against the Alpine **binary indexes** (dl-cdn APKINDEX, cached 24 h). The comparison is
per-arch against ONE index per arch — x86_64 and aarch64 are hardcoded (not derived from the apps' `arch:` lists) and
community is fetched with main only as a fetch fallback, so a package that lives only in main, or whose main version
diverges from community's, is validated against community's version or silently skipped. The apk-bump workflow's nudge
job merges main+community instead (main wins) and derives the arch list from each app's `config.yaml` — gate and nudge
can disagree in principle (alignment + parser dedupe: `TODO.md`). A mismatch fails `mise run check`, and the CI lint
workflow's **daily cron** flags drift within a day. The index serves only the current pkgrel (old ones disappear), so
the next build would break anyway — the drift check turns an Alpine-side repoint into a guided release instead of silent
image drift.

**Renovate opens the update PR, including the `config.yaml` version bump**: the Dockerfile manager extracts
`apk add pkg=version` pins into the `apk` datasource, and the apk packageRule in `.github/renovate.json` supplies the
dl-cdn APKINDEX `registryUrls` (branch plus arch pinned — without them Renovate silently skips the pins, it cannot infer
the Alpine branch from the base-image ARG) plus a `bumpVersions` entry that patch-bumps the app's `config.yaml` in the
same PR (matchString anchored at line start via `(?:^|\n)` emulation — Renovate compiles matchStrings without the `m`
flag, so a plain `^` would bind to file offset 0; only the FIRST match per file is bumped). The version-guard workflow
still passes on the Renovate PR as opened. `postUpgradeTasks` need `allowedPostUpgradeCommands` — a self-hosted-only
option — so the changelog entry is filled post-merge by the CI changelog job instead. The rule's registryUrls branch
value must be updated together with the Dockerfile's `BUILD_FROM` default on a base-image bump; the validate.py drift
check derives the branch dynamically and remains the config-independent net. Floating apk packages are skipped
(`unspecified-version`), as intended.

**Release automation (since 2026-10-18)**, chained apk rules in `.github/renovate.json`: pkgrel-only bumps (`1.22-r7` →
`1.22-r8`, classified `patch`) **automerge once CI is green** (rebase strategy — linear history); pkgver bumps get the
`needs-review` label and stay manual (CLI semantics may change). `platformAutomerge: false` keeps merges on Renovate's
own path (branch protection and "Allow auto-merge" are off today; the explicit setting prevents a later repo-toggle
enablement from merging before CI finishes). Post-merge, the apk-bump workflow's changelog job (a merged `renovate[bot]`
PR labeled `apk_pin`) inserts the templated `## <version>` section via the shared `apk-changelog` mise task —
idempotent, a pre-written section is never touched. The same workflow's nudge job (daily 01:30 UTC,
`workflow_dispatch`-able with a `dry_run` input) comments `@renovate rebase` (capped at 3 per PR) once ALL of the app's
arch indexes serve the new pin: an early bump PR legitimately stays red until the lagging arch's index catches up, and
re-running failed check runs can still count as red in Renovate's automerge evaluation. Missed image publishes self-heal
via the publish-reconcile workflow (daily 03:15 UTC): GHCR version-tag probes for every app (per-arch tags plus the
multi-arch manifest, anonymous `docker buildx imagetools inspect`; not-found-class errors mean a missing tag, other
failures are retried with backoff then fail red) dispatch `build-app.yaml` (`workflow_dispatch`-able; publish=true,
ref=main) on a genuine miss — idempotent, a healthy registry is a green no-op. Tag existence only: stale-content tags
are not detected. Tooling landscape (researched 2026-10-18): no OSS tooling exists for apk-pin bumping with arch gates
(linuxserver.io's scheduled external-trigger workflows are the closest precedent); Dependabot cannot bump apk pins at
all (dependabot-core#2129), updatecli has no apk/APKINDEX plugin, and Chainguard's `melange bump` rewrites melange build
YAML, not Dockerfiles.

Version-sensitive gotchas:

- **The aports source branch can outrun the binary index** (verified 2026-10: the `3.24-stable` APKBUILD said `pkgrel=8`
  while both arches' APKINDEX still served `1.22-r7`): a pin must be compared against what `apk add` actually resolves
  (the APKINDEX), not the APKBUILD source.
- The GitHub aports mirror (alpinelinux/aports) names stable branches `3.24-stable` (no `v` prefix, unlike the GitLab
  branches); raw fetches there are for source inspection only — version checks use dl-cdn.
- **The binary-index repush is per-arch and can skew between the arches** (verified 2026-10-16): in such a window the
  arches' indexes disagree, so *no* pin passes the strict per-arch equality check. Bump to the newest index version
  anyway: the repointed arch no longer serves the old package, so a cold-cache build of the stale pin breaks there (the
  builder's layer cache can mask this for a while), while the lagging arch's mismatch is transient and self-heals when
  its repush lands. Pinning the older version instead would leave both arches failing once the lagging arch repushes.
  During the window, a red check on the lagging arch is accurate signal.

## HA base image: shell gotchas

Facts; the safe procedures (procfs writes, suppression of failed-redirection diagnostics, environment passing, PATH,
bashio stubbing): skill `ha-app-base-image`.

- **`echo`/`printf` emit a single `writev(2)`**: the base image's bash (5.3.9) implements the output of its `echo` and
  `printf` builtins as one `writev(2)` call, with the text and the trailing newline as separate iovecs. Kernel files
  that only implement the old-style single-buffer `.write` and no `.write_iter` (many procfs/sysfs transaction files,
  e.g. `/proc/fs/nfsd/*`) reject `writev(2)` with `EINVAL` — producing a misleading `write error: Invalid argument` that
  is about the syscall *shape*, not the written content. Callers that do a single `write(2)` (busybox `echo`, `cat`,
  many C daemons' own writes) succeed. (Which files this bites in a given app: the app's `KNOWLEDGE.md`.)
- **Failed redirections bypass the command's `2>/dev/null`**: a failed redirection is diagnosed by the shell itself,
  *before* the command's own redirections are in effect.
- **`with-contenv` wipes the inherited environment unless `S6_KEEP_ENV=1`**: the s6-overlay shebang helper runs
  `emptyenv -p` and then imports only `/run/s6/container_environment` (the variables the supervisor/s6 boot provides).
  Anything exported by a calling shell or `docker run -e` is erased — unless `S6_KEEP_ENV=1` is set, which makes
  `with-contenv` pass the inherited environment through untouched (production s6-rc boots are unaffected: there the env
  arrives via `container_environment` either way).
- **PATH differs between `docker exec` and s6 services**: the image's ENV PATH (HA base image default, no `/command`) is
  what `docker exec` inherits; services started by s6-rc see an *augmented* PATH instead (s6-overlay v3's preinit writes
  `/command` into `/run/s6/container_environment`; observed 2026-10-21, hd-idle 0.1.9). Version-sensitive: re-verify
  against the s6-overlay version shipped by the base image before relying on it.
- **Stubbing `bashio::config` in bare-container script tests**: `bashio::config` fetches the app options from the
  Supervisor API (`bashio::app.config` → `GET /addons/self/options/config`), backed by a file cache — it never reads
  `/data/options.json`. Seeding `${CACHE_DIR}/addons.self.options.config.cache` (env override `CACHE_DIR`; the key is
  fixed, `bashio::cache` appends `.cache` and validates `^[A-Za-z0-9._-]+$`) with the crafted options JSON stubs the API
  exactly (the cache stores the raw response). Requires the `S6_KEEP_ENV=1` gotcha above, since `CACHE_DIR` is an
  inherited variable.

## bashio option consumption

How scripts consume options through bashio — read from `/usr/lib/bashio/{config,jq}.sh` inside the built image
(ghcr.io/home-assistant/base:3.24, 2026-10). Stubbing `bashio::config` for script tests: §"HA base image: shell
gotchas".

- **Array options come out one element per line**: `bashio::config '<array option>'` iterates `.key[]` through
  `jq -r -c -M` (bashio `lib/config.sh`) — string-array options as one RAW (unquoted) element per line, object-array
  options as one compact JSON object per line (fields are then read with `bashio::jq "${entry}" '.field'`).
- **The output has NO trailing newline** (`printf '%s'` of the `$()`-stripped jq stream): a `while read` fed directly
  from `bashio::config` silently drops the last element — capture the value into a variable and feed the loop via
  `< <(echo "${RAW}")` (`echo` re-terminates the final line).
- **Raw string lines must NOT go through `bashio::jq`**: jq parses the line as JSON, so an unquoted value like
  `127.0.0.0/8` fails with `jq: parse error: Invalid numeric literal` (exit 5) — only object lines (valid JSON) do.
- **`'<field> // empty'` is valid only for STRING-typed fields**: jq treats `false` as empty, so an optional BOOLEAN
  field cannot distinguish "absent" from "false" (absent → "null", false → "false") — optional per-item checkboxes are
  therefore modeled as `list(yes|no)?` dropdowns, not `bool?` (schema mechanics: §"Supervisor: option schema quirks").

App-specific uses and consequences: `hd-idle/KNOWLEDGE.md` §"bashio option parsing (list-of-object options)",
`hickory-dns/KNOWLEDGE.md` §"Option consumption (bashio)".

## s6-overlay: user bundles live OUTSIDE s6-rc.d

Adding a service to a bundle (e.g. the default `user` bundle) is done via
`/etc/s6-overlay/user-bundles.d/<bundle>/contents.d/<service>` — a path that must NOT be under `s6-rc.d/`. A stray
directory under `s6-rc.d/` (e.g. `s6-rc.d/user-bundles.d/`) is scanned by `s6-rc-compile` as a *service source
directory* and fails the whole boot
(`fatal: unable to read /etc/s6-overlay/s6-rc.d/user-bundles.d/type: No such file or directory`) — the container
crash-loops at preinit while the supervisor still reports the app state as "started". The symptom is invisible to health
checks (the container never reaches them), so any change under `rootfs/etc/s6-overlay/s6-rc.d/` or `user-bundles.d/`
must be lab-booted before deploy (skill `ha-app-lab-testing`).

**User-bundle services must declare a `dependencies.d/base` dependency** (empty *file*, per s6-overlay's MOVING-TO-V3
guidance): s6-rc brings the user bundle up in dependency order, and without a dependency on the built-in `base` bundle a
longrun can start BEFORE `legacy-cont-init` (the compat oneshot running `/etc/cont-init.d/*`) has completed — observed
as a daemon crash-looping until s6-supervise's restart loop finally started it after its cont-init-generated inputs
existed. Empty dependency *directories* are equally broken in a subtler way: git does not track them, so they silently
vanish from the image.

**Boot-completion oracle**: `legacy-services successfully started` (from
`s6-rc: info: service legacy-services successfully started`) is s6-rc's completion line for the compat oneshot that
links the classic `/etc/services.d` tree into `/run/s6/legacy-services` — the last thing s6-rc starts (after the user
bundle), and it starts and logs even when no classic services exist. That makes the line a reliable boot-complete marker
for any s6-overlay v3 container; the lab boot wait and the nfs-server live test rely on it. Version-sensitive
(s6-overlay v3 legacy compat; source: [just-containers/s6-overlay v3.2.3.2,
`doc/init.txt`](https://github.com/just-containers/s6-overlay/blob/v3.2.3.2/doc/init.txt) — re-verify on
base-image/s6-overlay bumps).
