---
name: ha-app-base-image
description: HA base image shell gotchas and safe procedures for app scripts — writing to procfs/sysfs transaction files
  (the writev/EINVAL trap), failed-redirection diagnostics, S6_KEEP_ENV, PATH differences between docker exec and s6
  services, and stubbing bashio::config in tests. Use when writing or debugging app shell scripts.
---

# HA base image shell gotchas

Mechanism facts: root `KNOWLEDGE.md` §"HA base image: shell gotchas". The procedures:

## Writing to procfs/sysfs transaction files (e.g. `/proc/fs/nfsd/*`)

The base image's bash `echo`/`printf` are single-`writev(2)` callers, which transaction files reject (mechanism and
misleading error text: root `KNOWLEDGE.md` §"HA base image: shell gotchas"). To write from app code:

- busybox `echo`, `cat`, or any single-`write(2)` caller works;
- when only bash is available, stage the string in a regular file (e.g. on tmpfs) and `cat` it into the target.

Per-app affected files are listed in the app's `KNOWLEDGE.md`.

## Suppressing failed-redirection diagnostics

Failed-redirection diagnostics bypass the command's own `2>/dev/null` (root `KNOWLEDGE.md` §"HA base image: shell
gotchas"). To capture message and exit code: `out=$( (echo x > /ro/path) 2>&1 )`.

## Environment passing

Scripts invoked via `docker exec` (or tests seeding inherited variables) need `S6_KEEP_ENV=1` — `with-contenv` otherwise
wipes the inherited environment (facts: root `KNOWLEDGE.md` §"HA base image: shell gotchas").

## PATH

s6-rc services see `/command` prepended; `docker exec` does not (facts: root `KNOWLEDGE.md` §"HA base image: shell
gotchas"). Exec-driven commands must therefore call s6 tools by absolute path (`/command/s6-svc`).

## Stubbing `bashio::config` in bare-container script tests

`bashio::config` fetches the app options from the Supervisor API via a file cache — it never reads `/data/options.json`
(facts: root `KNOWLEDGE.md` §"HA base image: shell gotchas"). Seed `${CACHE_DIR}/addons.self.options.config.cache` with
the crafted options JSON; requires `S6_KEEP_ENV=1`, since `CACHE_DIR` is an inherited variable. Worked example:
hd-idle's per-drive decision-matrix tests.

## s6-overlay wiring

User-bundle services: directories under `/etc/s6-overlay/user-bundles.d/`, never under `s6-rc.d/`; every service needs
an empty `dependencies.d/base` file (facts: root `KNOWLEDGE.md` §"s6-overlay: user bundles live OUTSIDE s6-rc.d"). Any
change under those trees must be lab-booted before deploy (`mise run test:lab <app>` — skill `ha-app-lab-testing`).
