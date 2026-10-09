# TODOs

Short dev items first, then the security hardening plan; resolved items at the
bottom. Underlying technical facts and root causes live in `KNOWLEDGE.md`.

## Tasks

- Investigate mise task-arg-forwarding feature gap (see the `test:live` task source's comment header) and fix it upstream if indicated.

- Create upstream PR in HA to render app configuration labels in the UI as Markdown blocks instead of the current single-line plain text.

- Work through the security hardening plan below (items 1–3 remain; 4–5 are done).

- ~~After the first successful CI publish, verify images are cosign-signed (signed → +1 security rating).~~

  **Resolved as a dead end:** images may well be signed, but it cannot *raise
  the rating*: supervisor's `AppModel.signed` is a hardcoded `False` stub
  ("Currently no signing support", verified in 2026.09.3 and 2026.10.1) —
  the +1 branch of `rating_security` is unreachable for every app. Keep
  signing as supply-chain hygiene (worth having when upstream ships
  verification).

- Investigate real NFSv4 client recovery tracking in the container (see `KNOWLEDGE.md`): ship `nfsdcld` (cld tracker), mount rpc_pipefs per-netns in the container, keep its sqlite store on `/data` – gives clients state reclaim across app restarts (and enables the kernel's own grace-period skip path). Verify the per-netns rpc_pipefs upcall channel works in a privileged container first.

## Security hardening plan

Where the app stands security-wise, and why:

- Runs as root in its own container. Requires `SYS_ADMIN` (to mount the nfsd
  filesystem in the app's own procfs/network namespace; the nfsd kernel module
  itself is loaded by the kernel's mount-time autoload, outside the app —
  device-verified, see `KNOWLEDGE.md`).
- `apparmor: true` with a custom profile (`apparmor.txt`, hardening item 3,
  device-enforcement-verified); no `full_access`, no `docker_api`, no
  `host_pid` → **protection mode can stay enabled**: the `privileged`
  capability list applies regardless of protection mode; only
  `full_access`/`docker_api`/`host_pid` are gated by it (none of which we
  use).
- Supervisor security rating today: **5**, device-verified (the UI shows the
  same). Decomposition from the actual formula
  (`supervisor/apps/utils.py::rating_security` at
  https://github.com/home-assistant/supervisor/blob/2026.09.3/supervisor/apps/utils.py):
  base 5, +1 for the AppArmor profile, −1 for the `SYS_ADMIN` capability, and
  **no further contributions**: the "no exposed ports" +2 branch is
  incompatible with the app (NFS needs the published 2049/tcp), the `signed`
  +1 is dead code in current supervisors (`AppModel.signed` is a stub
  returning `False` for all apps, "Currently no signing support" — verified
  in 2026.09.3 and 2026.10.1), and we use no role/host-namespace knobs.
  Ceiling with the current design: 5. Ceiling via upstream item 2 (drop
  `SYS_ADMIN` through a host-side nfsd mount): 6.

### 1. Upstream: `CONFIG_NFSD=m` in all HAOS board kernels *(do first)*

Today only Rockchip-based boards (odroid-m1/m1s, Home Assistant Green) have
the module at all — every other HAOS board can't run the app.

- Where: `buildroot-external/kernel/v6.18.y/` – shared `haos.config` fragment
  (preferred) or the per-SoC configs (`kernel-arm64-rockchip.config` already
  has it); boards missing it: Raspberry Pi 3/4/5, generic-aarch64,
  generic-x86_64, odroid c2/c4/n2, khadas-vim3, ova.
- Facts for the request (from HAOS sources and a reference kernel):
  - The NFS *client* (`CONFIG_NFS_FS=y`) is already built into all board
    kernels (#4762/#4773), so the `sunrpc`/`lockd`/`grace` infrastructure is
    already there; nfsd mainly adds `nfsd.ko` itself.
  - HAOS already ships `rpcbind` and `nfs-utils` (client tools) on every
    board; `rpcbind` even runs unconditionally.
  - Module cost, measured on a comparable x86_64 kernel: `nfsd.ko.xz` ≈
    417 KB compressed; loaded only when something mounts the nfsd
    filesystem, so zero runtime cost otherwise.
  - Containment: the kernel nfsd of the app runs in the app's network
    namespace and resolves export paths in the app's mount namespace, so it
    only ever serves files the app could read anyway.
- Expected counterarguments & responses:
  - *Image/RAUC slot size grows* → ~0.4 MB compressed per board image vs
    multi-GB images; one line in the shared kernel config fragment.
  - *Kernel attack surface* → the module stays unloaded until used; the
    app-side exposure is confined (AppArmor + namespaces).
  - *"HAOS is not a NAS"* → official apps already include file/infra servers
    (Samba share app), and HAOS ships USBIP and rpcbind support; an NFS
    server completes the existing NFS *client* support.
  - *Per-board maintenance* → putting it in the shared fragment avoids that.
- Action: open an issue in home-assistant/operating-system with these facts,
  then a PR. If rejected: keep the per-board support matrix in `DOCS.md`.

### 2. Upstream: host-side nfsd mount + supervisor bind-mount *(exploratory)*

Goal: eliminate `SYS_ADMIN` entirely (the app-side module loading is already
gone — the kernel's mount-time autoload loads nfsd itself).

- Key insight (see `KNOWLEDGE.md`): the nfsd filesystem is instantiated per
  network namespace — mounted by whom, for whose netns. The app runs nfsd in
  the *container's* netns, so the control filesystem must be mounted *inside
  the container* (or the app must share the host netns). A host-side mount
  alone therefore does **not** help a bridge-network app: its bind-mount into
  the container would carry the *host*-netns instance, mismatching the
  container's nfsd.
- Sketch: HAOS ships a systemd `proc-fs-nfsd.mount` unit (plenty of `.mount`
  unit precedent) — better a `.automount` unit so the kernel module only
  loads when actually used; supervisor gains binding the host's
  `/proc/fs/nfsd` into apps on demand (verified: docker accepts bind-mounting
  that path); the app then runs with `host_network: true`, reads/writes the
  control files directly (single-`write(2)` callers work), and drops
  `privileged`, `kernel_modules` entirely.
- Tradeoffs / counterarguments (why exploratory):
  - Supervisor feature for one fstype → feature-creep discussion; a generic
    `mounts:` option would be a much bigger design debate.
  - `host_network: true` shares the host netns (reachability of host's
    localhost services) — the security docs discourage it; rating math
    cancels out (−1 host_network replaces −1 privileged), so the *rating*
    wouldn't improve; the real win is zero capabilities, the real cost is
    weaker network isolation.
  - Version coupling: would need a fallback path for older HAOS/supervisor.
- Action: only if item 1 is accepted, file the mount-unit PR on
  operating-system and a discussion/PR on supervisor with the netns
  analysis; implement the app-side switch only if welcomed upstream.

### 3. Local: AppArmor profile *(independent of upstream)* — **implemented, device-enforcement-verified (October 2026)**

Ground truth from supervisor sources (`utils/apparmor.py`, `apps/app.py`,
`docker/app.py`, `apps/model.py`):

- `apparmor` in `config.yaml` is boolean-only. With `true`, supervisor
  installs `apparmor.txt` into the host's AppArmor store on install/update
  and **renames the first (top-level) `profile <name>` to the installed
  slug** (`local_nfs` while testing, `<hash>_nfs` when installed from the
  store); the container then runs with that profile. Requirements for the
  file: exactly one top-level (non-indented) `profile` declaration; nested
  sub-profiles must be indented so the `^profile` regex doesn't match them.
  The declared name is otherwise arbitrary.
- So: keep `apparmor: true`, and rework our (currently unused)
  `apparmor.txt`, modeled on the dnsmasq app's profile (single file with
  `cx` sub-profiles) with the tailscale app's modernized s6/bashio blocks.
- Rules to add beyond the standard s6/bashio/`/data` blocks:
  - `mount fstype=nfsd /proc/fs/nfsd/,` plus `r`/`w` on `/proc/fs/nfsd/**`
    (`rpc.nfsd` writes `versions`/`portlist`/`threads` with plain `write(2)`;
    the cont-init script reads them)
  - `/etc/exports rw`, `/var/lib/nfs/** rw` (export table, v4 recovery dir)
  - `/lib/modules/** r` (modprobe), execute access for `mount`, `ip`,
    `exportfs`, `rpc.nfsd`, `rpc.mountd` (the latter two via `cx`
    sub-profiles); `r`/`w` on the pseudo-root tree `/data/pseudo_root/**`
    (bind mounts + `/etc/exports` generation live there)
  - capabilities per complain-mode analysis (expect `dac_override`; the old
    profile's `net_bind_service`/`setuid`/`setgid`/raw-network entries are
    probably unnecessary for an NFSv4-only setup — verify, don't carry over)
- Process: iterate with the profile in complain mode on the test device
  (supervisor logs the denials), tighten until clean, then enforce.
- Acceptance: app starts, exports and serves files with `apparmor: true` +
  loaded profile; app linter passes.

**State (original plan above; several parts were overturned — see the
findings):** implemented and device-enforcement-verified on-device (October
2026). The planned complain-mode iteration turned out impossible: HAOS's
kernel produces no AppArmor audit/denial messages in the host journal at all
(no usable audit plumbing), so denials are silent. Iteration instead ran in
enforce mode via the `deploy` task (version bump per round — `App.rebuild()`
skips `install_apparmor()`, only `App.update()` re-installs the profile),
diagnosing failures from boot progress + busybox errno forensics +
in-container ground truth (`/proc/self/attr/current`, `/proc/self/status`
CapEff). Two findings contradicted the static analysis: (1) the mount rule
must match the device string `nfsd` as mount source (not a path), and (2)
AppArmor mediates `capable(CAP_SYS_ADMIN)` during the mount syscall itself —
profiles need explicit `capability` rules even when the mount rule passes
(Docker's default profile carries a blanket `capability,`, plain Docker
containers never hit this). See `KNOWLEDGE.md` for the full gotcha list.

**Acceptance status:** app boots and serves with the profile enforcing
(verified live: NFS client roundtrips — write/read/delete on the default
share, read-only export rejection, pseudo-root browse — via the
`test:live` task), including after a fresh device **reboot**. The
module-loading question is resolved by *removal*: the kernel's
mount-time autoload loads nfsd in kernel context, outside the AppArmor
label, so the app carries no `modprobe`/`sys_module`/`/lib/modules`
access at all (device-verified by rebooting with the module unloaded;
see `KNOWLEDGE.md`).

### 4. Local: validate share inputs in the schema *(cheap hardening)* — **done in 0.3.3**

- Implemented: `match()` regexes on all three share fields (path: clean
  absolute path under `/share`/`/media`; network/options: no whitespace,
  no parentheses, non-empty comma-separated option tokens) — defense in
  depth against malformed `/etc/exports` entries (newline injection =
  extra export lines parsed as root). Note: supervisor's `match()` uses
  `vol.Match` (search semantics), hence the explicit `^…$` anchors; and
  the regex strings must not contain literal `\t`/`\n` escapes (YAML
  double-quoted scalars would turn them into real control characters,
  breaking the schema-element parse) — express via `\\s` instead.
- Verified against the real supervisor `AppOptions` validation code (fetched
  from the pinned ref): defaults accepted, all malformed variants rejected
  with the regex message the UI will show.

### 5. Local: user-facing security notes & defaults — **done in 0.3.3**

- Implemented: "Security notes" section in `DOCS.md` (no cryptographic
  authentication with `sec=sys`; the share's `network` option is the access
  control while the published port listens on all host interfaces;
  read-only-by-default exports; root squashing) and the default share
  options no longer enable `async` (`sync` is the `exports(5)` default;
  `async` remains user-selectable per share).
- Remaining: after the first successful CI publish, verify images are
  cosign-signed (signed → +1 rating) — moved to the Tasks list since it is
  a one-off check, not hardening work.

## Resolved

- ~~The host's kernel doesn't include the `nfsd` kernel module and hence the container can't load that module.~~

  **Resolved:** the app mounts the `nfsd` filesystem on startup (which also
  autoloads the `nfsd` kernel module on hosts that ship it). HAOS includes
  the module (`CONFIG_NFSD=m`) for Rockchip-based boards – verified for HAOS
  18.3; broader coverage is now upstream hardening item 1. Follow-ups on the
  `echo`-to-`/proc/fs/nfsd/*` `EINVAL` issue and the rpc.nfsd design facts
  live in `KNOWLEDGE.md`.
