---
name: hickory-dns-runtime
description: Runtime architecture and procedures for the hickory-dns Home Assistant app — the genconfig flow,
  named.toml shape, the s6 never-root launcher, the offline regression sandbox for the generator, and on-device
  debugging with the hickory-dns-utils CLIs. Use before touching hickory-dns runtime code, its s6 services, or when
  debugging the app on a device.
---

# hickory-dns runtime

All facts (config shape, option semantics, privileges, pins) live in `hickory-dns/KNOWLEDGE.md` — cited below by
section, never restated. Repository-wide mechanics (AppArmor, supervisor, base image): repository-root `KNOWLEDGE.md`.

## Architecture orientation

The app generates its whole configuration from the options at boot; nothing is hand-edited at runtime:

- `/usr/bin/hickory-dns-genconfig` — the cont-init generator: reads the options, resolves hostname upstreams, emits
  named.toml + static zone files + the service args file + the resolution cache, and validates the result with the real
  binary before anything is installed (facts: `hickory-dns/KNOWLEDGE.md` §"Generated named.toml", §"Upstream option
  model").
- `/data/named.toml` — the daemon config; `/data/hickory-dns.upstreams.cache` — last-known-good resolutions;
  `/etc/hickory-dns/zones/{default,static}/` — shipped and generated zone files (layout: §"Config-file and data
  layout").
- `/etc/hickory-dns.args` — the s6 service command line; the longrun `run` script reads it and execs the daemon via
  setpriv (never-root launch: §"Port 53 binding and privileges").
- `/usr/bin/hickory-dns-healthcheck` — the Docker HEALTHCHECK probe (§"Healthcheck").
- cont-init: `/etc/cont-init.d/config.sh`; s6 services: `hickory-dns` (longrun; user-bundle member with a
  `dependencies.d/base` dependency — repository-root `KNOWLEDGE.md` §"s6-overlay: user bundles live OUTSIDE s6-rc.d").

## Boot sequence

1. cont-init `config.sh` runs `hickory-dns-genconfig` under `set -euo pipefail`; any validation failure
   (`bashio::exit.nok`) aborts the app boot with the message in the app log.
2. The generator validates the *new* config with `hickory-dns --validate` (parses the TOML and loads every zone file)
   before moving it into place — a bad option becomes a boot failure, never a running daemon with a broken config.
3. The `hickory-dns` longrun fails loudly when the args file is missing (s6 restarts it; the log points at the
   configuration error) and otherwise execs the daemon as `nobody` with the ambient `CAP_NET_BIND_SERVICE`.

## Offline regression sandbox

The generator's behavior is regression-tested outside the app container (the lab covers the real-image path instead;
facts: `hickory-dns/KNOWLEDGE.md` §"Generator regression sandbox"). Recreate per session under `/tmp/hickory-test/`:

1. **Copy and adapt**: copy `hickory-dns-genconfig` into the sandbox and rewrite its path variables (`CONFIG`,
   `CONFIG_NEW`, `ARGS_FILE`, `ZONES_DIR`, `STATIC_DIR`, `CACHE`) to a temp tree — the script targets absolute
   `/data`/`/etc` paths and would otherwise write the dev host's real filesystem (misleading `mkdir: Permission denied`
   failures).
2. **Stub the binaries on PATH**: replace `/usr/bin/resolve` (canned ANSWER sections for known names, exit 1 otherwise)
   and `/usr/bin/hickory-dns` (accepts `--validate`; reject deliberately-broken configs) with stubs.
3. **Stub bashio semantics exactly**: string-array options as one RAW element per line, object-array options as one
   compact JSON object per line, both WITHOUT a trailing newline (repository-root `KNOWLEDGE.md` §"bashio option
   consumption") — a stub that appends `\n` hides the last-element-drop class of bugs.
4. **Run the scenario matrix**: validation rejections (protocol, host, IP, port, CIDR, path charset), ACL handling
   (loopback append, empty list), resolution paths (fresh lookup, cache fallback, corrupted cache line, lookup timeout),
   and the default options' full output — diff named.toml, the args file and the zone files byte-for-byte against a
   snapshot from the last verified revision.

## Debugging on a device or in the lab

- Query the running daemon with the shipped client CLI:
  `docker exec -it addon_<slug> dns -n 127.0.0.1:53 query localhost A`; reachability to an upstream:
  `dns -n <ip>:<port> ...` (plaintext checks only — the app's own upstream connections are TLS and show up in the app
  log on debug).
- The `resolve` CLI tests the system-resolver path the generator uses for hostname upstreams:
  `docker exec -it addon_<slug> resolve --system -t A <name>`.
- Debug mode maps to the daemon's `--debug` flag (§"Config-file and data layout"); `-q`/`-d`/`-p` and `RUST_LOG` are
  available for manual `docker exec` sessions.
- The named.toml + zone files in `/data`/`/etc/hickory-dns/` are plain files — inspect the generated config directly
  when a `--validate` failure is unclear.

## Device-only verification

The launcher's capability path (setpriv drop under enforcement) was device-verified on 2026-10-24 (facts and
re-verification trigger: `hickory-dns/KNOWLEDGE.md` §"Port 53 binding and privileges"); the live hook is
`.mise/tasks/test/live/hickory-dns.sh` (contract: skills `ha-app-lab-testing`, `ha-app-device-testing`,
`ha-app-apparmor`). Re-run it after the apk bump.
