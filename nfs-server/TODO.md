# TODOs

Open work items only (resolved items live in git history). Underlying technical facts and root causes live in
`KNOWLEDGE.md`.

## Tasks

- Upstream: `CONFIG_NFSD=m` in all HAOS board kernels *(awaiting upstream decision)*

  Filed 2026-10-29 as [`home-assistant discussion #5334`](https://github.com/orgs/home-assistant/discussions/5334) (HAOS
  routes feature requests to org discussions — blank issues are disabled in the `home-assistant/operating-system` issue
  tracker). The full fact set, per-board matrix, cost/containment arguments, and the proposed change live in the
  discussion; this item only tracks state and next steps:

  - Prepared: branch `agent-nfsd-all-boards` in the local `home-assistant/operating-system` clone — moves the seven
    `CONFIG_NFSD*` lines from `kernel-arm64-rockchip.config` into the shared `haos.config` fragment of
    `buildroot-external/kernel/v6.18.y/` — plus untracked drafts `agent-draft-proposal.md` / `agent-draft-pr.md` in that
    clone's root.
  - Submit it (fork → push branch → PR against `dev`, referencing the discussion) once maintainers signal approval
    there, or if there is no reaction within 30 days (by 2026-11-28). Per the upstream AI policy (`AI_POLICY.md`), a
    human must review and own everything posted — no autonomous submission.
  - Raspberry Pi 3/4/5 and Yellow already ship `nfsd.ko`: the upstream `bcm2711`/`bcm2712` defconfigs pinned by HAOS set
    `CONFIG_NFSD=m` and no HAOS fragment disables it — support there rests on upstream defconfig contents, not on an
    explicit HAOS choice. Boards actually missing the module: generic-aarch64, generic-x86_64, ova, odroid-c2/c4/n2,
    khadas-vim3.

- Upstream: host-side nfsd mount + supervisor bind-mount *(exploratory)*

  Goal: eliminate `SYS_ADMIN` entirely (the app-side module loading is already gone — the kernel's mount-time autoload
  loads nfsd itself) — the only remaining security-rating lever (→ 6; why every other lever is out: `KNOWLEDGE.md`
  §"Security hardening — posture"). Requires supervisor support for binding the host's `/proc/fs/nfsd` into apps on
  demand plus a HAOS `.automount` unit, and the app switching to `host_network: true` (the nfsd filesystem is
  instantiated per network namespace — a plain host-side mount does not help bridge-network apps; netns analysis:
  `KNOWLEDGE.md` §"Security hardening — posture"). Only pursue if the `CONFIG_NFSD` item above is welcomed upstream:
  file the mount-unit PR on operating-system and a supervisor discussion/PR with the netns analysis; implement the
  app-side switch only if welcomed.

- Upstream: render app configuration labels as Markdown blocks instead of plain text (frontend)

  Submitted [`home-assistant/frontend#54839`](https://github.com/home-assistant/frontend/pull/54839), rejected. Seems we
  have to wait for [OpenHomeFoundation/roadmap#57](https://github.com/OpenHomeFoundation/roadmap/issues/57) to get
  implemented.

- Device-side verification of the real HAOS trigger path for nfsd-watch: rslave propagation of drive mounts under
  `/media` into the app container (`KNOWLEDGE.md` §"Automatic mirror refresh (nfsd-watch)" states the expectation from
  supervisor `docker/app.py`; the lab's plain-Docker mirrors cannot reproduce it). Plug a drive in, mount it under
  `/media`, and confirm the watcher's detection + rebind cycle fires without an app restart.

- Unit-test nfsd-apply's share-validation matrix and exit codes (out-of-root path, non-absolute path,
  whitespace/backslash, duplicate (path, network) with identical vs conflicting options) — zero coverage today. Use the
  `bashio::config` stubbing procedure (root `KNOWLEDGE.md` §"HA base image: shell gotchas", skill `ha-app-base-image`).

- Stale mirror directories of removed shares accumulate on `/data`: nfsd-apply only creates mirrors (`mkdir -p` + bind),
  it never removes the mirror of a deleted share — empty leftovers stay visible to NFSv4 clients under the pseudo root.
  Track removed (path, network) pairs and rmdir an orphaned mirror once no remaining share uses the path (mind the
  dedup: a path may back several shares across networks).

- Resolve the rpc.mountd socket-behavior contradiction (device strace): `KNOWLEDGE.md` §"mountd and the pseudo file
  system root" and the runtime skill say "binds no ports, only services upcalls" while the `apparmor.txt` mountd comment
  says "actual RPC server (MNT service sockets TCP/UDP, v4+v6)" — both cannot be true; the answer decides whether
  mountd's `net_bind_service` + network grants are live surface.

- AppArmor sub-profiles: the unscoped `signal (send)` grants are template-inherited and unused (nothing in the app sends
  signals; s6-svc talks to s6 over its control fifo, not kill(2)). Scope or drop them — device-verify first (no audit
  logs on HAOS: skill `ha-app-apparmor`).
