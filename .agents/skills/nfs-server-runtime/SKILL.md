---
name: nfs-server-runtime
description: Runtime architecture, maintenance procedures, and debugging playbook for the nfs-server Home Assistant app
  — pseudo-root mirror design, nfsd-apply/nfsd-watch cycles, grace-period and client-recovery behavior, and how to
  diagnose on-device issues. Use before touching nfs-server runtime code, its s6 services, or when debugging the app on
  a device.
---

# nfs-server runtime

> Content being filled by the docs-cleanup app pass. Skeleton of intended sections (facts stay in
> `nfs-server/KNOWLEDGE.md` — reference, do not duplicate):
>
> 1. Architecture orientation — pseudo-root mirrors, `/etc/exports` generation, NFSv4-only setup
> 2. Boot sequence and s6 services — `cld`, `mountd`, `nfsd` oneshot, `nfsd-watch`, healthcheck
> 3. `nfsd-apply` modes and the watcher change cycle (umounts deepest-first, binds shallowest-first, `rpc.nfsd 0` first)
> 4. Debugging playbook — which logs carry what, NULL-RPC mount hangs, grace-period stalls, EBUSY cases, the
>    writev/EINVAL trap on `/proc/fs/nfsd/*` (skill `ha-app-base-image`)
> 5. Extending — adding a share option, changing detection, release considerations
