---
name: ha-app-base-image
description: HA base image shell gotchas and safe procedures for app scripts — writing to procfs/sysfs transaction files
  (the writev/EINVAL trap), failed-redirection diagnostics, S6_KEEP_ENV, PATH differences between docker exec and s6
  services, and stubbing bashio::config in tests. Use when writing or debugging app shell scripts.
---

# HA base image shell gotchas

Mechanism facts: root `KNOWLEDGE.md` §"HA base image: shell gotchas". The procedures:

## Writing to procfs/sysfs transaction files (e.g. `/proc/fs/nfsd/*`)

The base image's bash `echo`/`printf` emit a single `writev(2)`; transaction files (old-style `.write`, no
`.write_iter`) reject it with a misleading `write error: Invalid argument` — about the syscall shape, not the content.
To write from app code:

- busybox `echo`, `cat`, or any single-`write(2)` caller works;
- when only bash is available, stage the string in a regular file (e.g. on tmpfs) and `cat` it into the target.

Per-app affected files are listed in the app's `KNOWLEDGE.md`.

## Suppressing failed-redirection diagnostics

A failed redirection is diagnosed by the shell itself, before the command's own redirections are in effect —
`echo x > /some/ro/path 2>/dev/null` still prints the error. To suppress or capture it:
`out=$( (echo x > /ro/path) 2>&1 )` captures message and exit code.

## Environment passing

`with-contenv` wipes the inherited environment unless `S6_KEEP_ENV=1` is set (then the inherited environment passes
through untouched; production s6-rc boots are unaffected either way — their environment arrives via
`/run/s6/container_environment`). Needed e.g. when stubbing bashio's cache directory in tests.

## PATH

`docker exec` sees the image's ENV PATH (no `/command`); s6-rc services see `/command` prepended (s6-overlay preinit
writes `/run/s6/container_environment`). Exec-driven commands must therefore call s6 tools by absolute path
(`/command/s6-svc`). Version-sensitive: re-verify against the s6-overlay version shipped by the base image before
relying on it.

## Stubbing `bashio::config` in bare-container script tests

`bashio::config` fetches the app options from the Supervisor API, backed by a file cache — it never reads
`/data/options.json`. Seed `${CACHE_DIR}/addons.self.options.config.cache` with the crafted options JSON (the key is
fixed; `bashio::cache` appends `.cache` and validates `^[A-Za-z0-9._-]+$`). Requires `S6_KEEP_ENV=1`, since `CACHE_DIR`
is an inherited variable. Worked example: hd-idle's per-drive decision-matrix tests.

## s6-overlay wiring

User-bundle services: directories under `/etc/s6-overlay/user-bundles.d/`, never under `s6-rc.d/`; every service needs
an empty `dependencies.d/base` file (otherwise a longrun can start before `legacy-cont-init` has completed). Any change
under those trees must be lab-booted before deploy (`mise run lab <app>` — skill `ha-app-lab-testing`). Facts: root
`KNOWLEDGE.md` §"s6-overlay: user bundles live OUTSIDE s6-rc.d".
