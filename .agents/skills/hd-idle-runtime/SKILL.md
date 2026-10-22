---
name: hd-idle-runtime
description: Runtime architecture and procedures for the hd-idle Home Assistant app — the
  hd-idle-genargs/drives/pmfix/watch flow, the --check baseline replay, SG_IO privileges, drive-ID conventions, and
  restart semantics. Use before touching hd-idle runtime code, its s6 services, or when debugging the app on a device.
---

# hd-idle runtime

> Content being filled by the docs-cleanup app pass. Skeleton of intended sections (facts stay in `hd-idle/KNOWLEDGE.md`
> — reference, do not duplicate):
>
> 1. Architecture orientation — hd-idle-genargs, the args/drives/resolution files, hd-idle-watch, hd-idle-pmfix
> 2. Boot sequence and s6 services — cont-init config.sh, the longrun watcher tick (`--quiet --check` baseline replay)
> 3. The change cycle — candidate regeneration, comparison, no-restart resync vs. hd-idle service restart
> 4. Drive-PM treatment flow — drives file as single source of truth, `--since` semantics, per-bridge reality
> 5. Debugging playbook — which logs carry what, detached-drive passthrough, duplicate-symlink rejection, restart
>    effects (spin state NOT spun up)
> 6. Extending — adding a per-drive option, release considerations
