# TODOs

Open work items only (resolved items live in git history). Underlying technical facts and root causes live in
`KNOWLEDGE.md`.

## Tasks

- Upstream: `CONFIG_NFSD=m` in all HAOS board kernels *(do first)*

  Today only Rockchip-based boards (odroid-m1/m1s, Home Assistant Green) ship the nfsd kernel module — every other HAOS
  board cannot run the app. Facts for the request (from HAOS sources and a reference kernel):

  - The NFS *client* (`CONFIG_NFS_FS=y`) is already built into all board kernels (upstream PRs #4762/#4773), so the
    `sunrpc`/`lockd`/`grace` infrastructure exists; nfsd mainly adds `nfsd.ko` itself.
  - HAOS already ships `rpcbind` and `nfs-utils` (client tools) on every board; `rpcbind` even runs unconditionally.
  - Module cost, measured on a comparable x86_64 kernel: `nfsd.ko.xz` ≈ 417 KB compressed; loaded only when the nfsd
    filesystem is mounted, so zero runtime cost otherwise.
  - Containment: the kernel nfsd of the app runs in the app's network namespace and resolves export paths in the app's
    mount namespace, so it only ever serves files the app could read anyway.
  - Boards missing the module: Raspberry Pi 3/4/5, generic-aarch64, generic-x86_64, odroid c2/c4/n2, khadas-vim3, ova.
    Where: `buildroot-external/kernel/v6.18.y/` — shared `haos.config` fragment (preferred, avoids per-board
    maintenance) or the per-SoC configs (`kernel-arm64-rockchip.config` already has it).
  - Expected counterarguments & responses: *image/RAUC slot size grows* → ~0.4 MB compressed per board image vs multi-GB
    images; *kernel attack surface* → the module stays unloaded until used, and the app-side exposure is confined
    (AppArmor + namespaces); *"HAOS is not a NAS"* → official apps already include file/infra servers (Samba share app),
    and HAOS ships USBIP and rpcbind support; an NFS server completes the existing NFS *client* support.
  - Action: open an issue in home-assistant/operating-system with these facts, then a PR. If rejected: keep the
    per-board support matrix in `DOCS.md`.

- Upstream: host-side nfsd mount + supervisor bind-mount *(exploratory)*

  Goal: eliminate `SYS_ADMIN` entirely (the app-side module loading is already gone — the kernel's mount-time autoload
  loads nfsd itself) — the only remaining security-rating lever (→ 6; why every other lever is out: `KNOWLEDGE.md`
  §"Security hardening — posture"). Requires supervisor support for binding the host's `/proc/fs/nfsd` into apps on
  demand plus a HAOS `.automount` unit, and the app switching to `host_network: true` (the nfsd filesystem is
  instantiated per network namespace — a plain host-side mount does not help bridge-network apps; netns analysis:
  `KNOWLEDGE.md` §"Security hardening — posture"). Only pursue if the `CONFIG_NFSD` item above is welcomed upstream:
  file the mount-unit PR on operating-system and a supervisor discussion/PR with the netns analysis; implement the
  app-side switch only if welcomed.

- Investigate mise task-arg-forwarding feature gap (the `test:live` task forwards its depends-args via a run script —
  see `.mise/tasks/test/live/`) and fix it upstream if indicated.

- Upstream: render app configuration labels as Markdown blocks instead of plain text (frontend)

  Submitted [`home-assistant/frontend#54839`](https://github.com/home-assistant/frontend/pull/54839), rejected. Seems we
  have to wait for [OpenHomeFoundation/roadmap#57](https://github.com/OpenHomeFoundation/roadmap/issues/57) to get
  implemented.
