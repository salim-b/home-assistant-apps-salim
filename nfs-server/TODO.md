# TODOs

Short dev items first; resolved items at the bottom. Underlying technical
facts and root causes live in `KNOWLEDGE.md`.

## Tasks

- Investigate mise task-arg-forwarding feature gap (see the `test:live` task source's comment header) and fix it upstream if indicated.

- Create upstream PR in HA to render app configuration labels in the UI as Markdown blocks instead of the current single-line plain text.

- Upstream: `CONFIG_NFSD=m` in all HAOS board kernels *(do first)*

  Today only Rockchip-based boards (odroid-m1/m1s, Home Assistant Green)
  ship the nfsd kernel module — every other HAOS board cannot run the app.
  Facts for the request (from HAOS sources and a reference kernel):

  - The NFS *client* (`CONFIG_NFS_FS=y`) is already built into all board
    kernels (upstream PRs #4762/#4773), so the `sunrpc`/`lockd`/`grace`
    infrastructure exists; nfsd mainly adds `nfsd.ko` itself.
  - HAOS already ships `rpcbind` and `nfs-utils` (client tools) on every
    board; `rpcbind` even runs unconditionally.
  - Module cost, measured on a comparable x86_64 kernel: `nfsd.ko.xz` ≈
    417 KB compressed; loaded only when the nfsd filesystem is mounted, so
    zero runtime cost otherwise.
  - Containment: the kernel nfsd of the app runs in the app's network
    namespace and resolves export paths in the app's mount namespace, so it
    only ever serves files the app could read anyway.
  - Boards missing the module: Raspberry Pi 3/4/5, generic-aarch64,
    generic-x86_64, odroid c2/c4/n2, khadas-vim3, ova. Where:
    `buildroot-external/kernel/v6.18.y/` – shared `haos.config` fragment
    (preferred, avoids per-board maintenance) or the per-SoC configs
    (`kernel-arm64-rockchip.config` already has it).
  - Expected counterarguments & responses: *image/RAUC slot size grows* →
    ~0.4 MB compressed per board image vs multi-GB images; *kernel attack
    surface* → the module stays unloaded until used, and the app-side
    exposure is confined (AppArmor + namespaces); *"HAOS is not a NAS"* →
    official apps already include file/infra servers (Samba share app), and
    HAOS ships USBIP and rpcbind support; an NFS server completes the
    existing NFS *client* support.
  - Action: open an issue in home-assistant/operating-system with these
    facts, then a PR. If rejected: keep the per-board support matrix in
    `DOCS.md`.

- Upstream: host-side nfsd mount + supervisor bind-mount *(exploratory)*

  Goal: eliminate `SYS_ADMIN` entirely (the app-side module loading is
  already gone — the kernel's mount-time autoload loads nfsd itself) — the
  only remaining security-rating lever (→ 6; see `KNOWLEDGE.md`,
  "Security hardening — posture and what is left", for why every other
  lever is out). Requires supervisor support for binding the host's
  `/proc/fs/nfsd` into apps on demand plus a HAOS `.automount` unit, and
  the app switching to `host_network: true` (the nfsd filesystem is
  instantiated per network namespace — a plain host-side mount does not
  help bridge-network apps; netns analysis in `KNOWLEDGE.md`). Only pursue
  if the `CONFIG_NFSD` item above is welcomed upstream: file the
  mount-unit PR on operating-system and a supervisor discussion/PR with
  the netns analysis; implement the app-side switch only if welcomed.

- ~~After the first successful CI publish, verify images are cosign-signed (signed → +1 security rating).~~

  **Resolved as a dead end:** images may well be signed, but it cannot *raise
  the rating*: supervisor's `AppModel.signed` is a hardcoded `False` stub
  ("Currently no signing support", verified in 2026.09.3 and 2026.10.1) —
  the +1 branch of `rating_security` is unreachable for every app. Keep
  signing as supply-chain hygiene (worth having when upstream ships
  verification).

## Resolved

- ~~Real NFSv4 client recovery tracking in the container~~

  **Done (October 2026):** shipped — `nfsdcld` (cld tracker, sqlite store on
  `/data`) plus the per-netns rpc_pipefs upcall channel; verified in
  privileged containers: the kernel uses the tracker and skips the grace on
  fresh boots ("no clients to reclaim, skipping NFSv4 grace period"), and a
  connected client reclaims its state across a server recreation (held
  exclusive flock survives, contested by a second client). Facts, wiring and
  the residual unknowns in `KNOWLEDGE.md`. Device-side verification of the
  enforcing-mode profile additions (rpc_pipefs mount rule, `nfsdcld`
  sub-profile) still pending.

- ~~The host's kernel doesn't include the `nfsd` kernel module and hence the container can't load that module.~~

  **Resolved:** the app mounts the `nfsd` filesystem on startup (which also
  autoloads the `nfsd` kernel module on hosts that ship it). HAOS includes
  the module (`CONFIG_NFSD=m`) for Rockchip-based boards – verified for HAOS
  18.3; broader coverage is the `CONFIG_NFSD` upstream task above. Follow-ups on the
  `echo`-to-`/proc/fs/nfsd/*` `EINVAL` issue and the rpc.nfsd design facts
  live in `KNOWLEDGE.md`.

- ~~Security hardening: AppArmor profile~~

  **Done (October 2026):** custom profile (`apparmor.txt`) enforced and
  device-verified (full boot, NFS client roundtrips, reboot with the module
  unloaded); supervisor profile mechanics and the on-device gotchas
  (capability mediation, missing audit logs, mount-rule grammar, network
  mediation) live in `KNOWLEDGE.md`.

- ~~Security hardening: validate share inputs in the schema~~

  **Done (0.3.3):** `match()` regexes on all share fields (defense in depth
  against malformed `/etc/exports` entries); the `match()` quirks are
  recorded in `KNOWLEDGE.md`.

- ~~Security hardening: user-facing security notes & defaults~~

  **Done (0.3.3):** "Security notes" section in `DOCS.md` (no cryptographic
  authentication with `sec=sys`; the share's `network` option is the access
  control while the published port listens on all host interfaces;
  read-only-by-default exports; root squashing); default share options use
  synchronous writes (`sync` is the `exports(5)` default; `async` remains
  user-selectable per share).
