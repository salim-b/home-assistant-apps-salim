# TODOs

Short dev items first, then the security hardening plan; resolved items at the
bottom. Underlying technical facts and root causes live in `KNOWLEDGE.md`.

## Tasks

- Create upstream PR in HA to render app configuration labels in the UI as Markdown blocks instead of the current single-line plain text.

- Work through the security hardening plan below (items 1–5, upstream-first).

## Security hardening plan

Where the app stands security-wise, and why:

- Runs as root in its own container. Requires `SYS_ADMIN` (to mount the nfsd
  filesystem in the app's own procfs/network namespace) and `SYS_MODULE` (via
  `kernel_modules`, for `modprobe` on hosts without module autoload).
- `apparmor: false` for now (hardening item 3); no `full_access`, no
  `docker_api`, no `host_pid` → **protection mode can stay enabled**: the
  `privileged` capability list and `kernel_modules` apply regardless of
  protection mode; only `full_access`/`docker_api`/`host_pid` are gated by it
  (none of which we use).
- Supervisor security rating today: 4 (base 5, −1 AppArmor disabled, −1 for
  `SYS_ADMIN`/`SYS_MODULE`, +1 once CI-signed images are published). With a
  working custom AppArmor profile: 6.

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

Goal: eliminate `SYS_ADMIN` (and `modprobe`/`SYS_MODULE`) entirely.

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

### 3. Local: AppArmor profile *(independent of upstream)*

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
    `exportfs`, `rpc.nfsd` (the latter two via `cx` sub-profiles)
  - capabilities per complain-mode analysis (expect `dac_override`; the old
    profile's `net_bind_service`/`setuid`/`setgid`/raw-network entries are
    probably unnecessary for an NFSv4-only setup — verify, don't carry over)
- Process: iterate with the profile in complain mode on the test device
  (supervisor logs the denials), tighten until clean, then enforce.
- Acceptance: app starts, exports and serves files with `apparmor: true` +
  loaded profile; app linter passes.

### 4. Local: validate share inputs in the schema *(cheap hardening)*

- `path`/`network`/`options` are user strings written verbatim into
  `/etc/exports` (newline injection = extra export lines; mostly
  self-inflicted, but `exportfs` parses that file as root). Add `match()`
  regexes to the schema (`path: ^/(share|media)(/.+)?$`, sane charsets for
  network and options) as defense in depth + better frontend errors.
- Keep the `config.sh` fatal check for unmapped paths (works regardless of
  schema support).

### 5. Local: user-facing security notes & defaults

- `DOCS.md` security section: NFSv4 with `sec=sys`/`AUTH_SYS` has no
  cryptographic authentication (identity = uid, LAN trust); the `network`
  option is the access control; port 2049 is published on **all** host
  interfaces by docker (not just the LAN the user intends) → recommend
  read-only exports and a trusted network; explain squashing (see the
  existing client-side permissions note).
- Default share options: add `no_subtree_check` (silences the `exportfs`
  notice); reconsider `async` (faster, but data loss on crash — `sync` is
  the `exports(5)` default).
- After the first successful CI publish, verify images are cosign-signed
  (signed → +1 rating).

## Resolved

- ~~The host's kernel doesn't include the `nfsd` kernel module and hence the container can't load that module.~~

  **Resolved:** the app mounts the `nfsd` filesystem on startup (which also
  autoloads the `nfsd` kernel module on hosts that ship it). HAOS includes
  the module (`CONFIG_NFSD=m`) for Rockchip-based boards – verified for HAOS
  18.3; broader coverage is now upstream hardening item 1. Follow-ups on the
  `echo`-to-`/proc/fs/nfsd/*` `EINVAL` issue and the rpc.nfsd design facts
  live in `KNOWLEDGE.md`.
