# Salim B's Home Assistant apps

This repository holds [@salim-b](https://github.com/salim-b)'s [Home Assistant
apps](https://www.home-assistant.io/getting-started/concepts-terminology/#apps).

[![Open your Home Assistant instance and show the <kbd>Add app repository?</kbd> dialog with Salim B's repository URL
pre-filled.](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fsalim-b%2Fhome-assistant-apps-salim)

## Apps

### [NFS Server](./nfs-server)

![Supports aarch64 Architecture][aarch64-shield] ![Supports amd64 Architecture][amd64-shield]

Turn your Home Assistant instance into a [Network File System (NFS)](https://en.wikipedia.org/wiki/Network_File_System)
server.

### [hd-idle](./hd-idle)

![Supports aarch64 Architecture][aarch64-shield] ![Supports amd64 Architecture][amd64-shield]

Spins down idle USB and SATA hard disk drives automatically.

### [Hickory DNS](./hickory-dns)

![Supports aarch64 Architecture][aarch64-shield] ![Supports amd64 Architecture][amd64-shield]

Turn your Home Assistant instance into a secure DNS server with encrypted upstream resolution (DNS-over-TLS/HTTPS/QUIC)
and DNSSEC validation.

## Development

The structure of all apps in this repository follows Home Assistant's [best
practices](https://contributors.home-assistant.io/apps/) as far as possible.

Non-obvious development knowledge lives in [`KNOWLEDGE.md`](./KNOWLEDGE.md) (repository-wide: supervisor behaviors,
AppArmor, base-image gotchas, testing) and in each app's own `KNOWLEDGE.md` (e.g.
[`hd-idle/KNOWLEDGE.md`](./hd-idle/KNOWLEDGE.md), [`nfs-server/KNOWLEDGE.md`](./nfs-server/KNOWLEDGE.md),
[`hickory-dns/KNOWLEDGE.md`](./hickory-dns/KNOWLEDGE.md)); step-by-step procedures live in the skills under
[`.agents/skills/`](./.agents/skills) (index in [`AGENTS.md`](./AGENTS.md)).

To test an app on your Home Assistant server (device), use the deploy mise tasks — `mise run <task> --help` has the
full, current usage (options, flags and what happens to the app's stored options); the examples below cover the common
flows:

```sh
# app name (repo subfolder) + SSH target of the device
mise run deploy nfs-server root@homeassistant.local

# switch a device from the locally installed app to the published registry
# version (after merging); --config decides the previous options' fate
mise run deploy-registry hd-idle root@homeassistant.local --config migrate

# get app logs (`--follow` continuously prints new log entries until you abort;
# app slug is `local_<config.yaml slug>`)
ssh root@homeassistant.local 'ha apps logs --follow local_nfs-server'
```

Note that the deploy tasks comment out the top-level `image:` key in the *device-side* copy of `config.yaml`: with an
`image` key set, the Supervisor would pull that image from GHCR instead of building locally from your working tree — see
the [dev docs](https://contributors.home-assistant.io/apps/guides/testing/#remote-development). An app already installed
**from an app repository** (not as a local app — such installs have a hashed store slug like `f8b2d53d_nfs-server`)
would conflict on the app's published port, so the tasks refuse; uninstall that copy first (the error message shows the
exact command) or pass `--replace` to have the task uninstall it automatically.

For a full end-to-end test, run `test:live` (for the `nfs-server` app, this includes an NFS client roundtrip against the
running app). It deploys the app, forwarding `--replace`/`--test-options`:

```sh
# plain: tests the device app's currently configured shares
mise run test:live nfs-server root@homeassistant.local

# with the repo's test options applied for the run (a minimal set exercising
# the whole export surface: default share, read-only share, /media share,
# nested path, second client network — your app options are backed up and
# restored automatically)
mise run test:live nfs-server root@homeassistant.local --test-options
```

## CI

On every push to `main`, the [Builder](./.github/workflows/builder.yaml) workflow builds each app whose relevant files
changed and publishes its container images to GHCR via the [Build app](./.github/workflows/build-app.yaml) workflow:
per-arch images (e.g. `ghcr.io/salim-b/amd64-app-nfs-server`) plus a multi-arch manifest (e.g.
`ghcr.io/salim-b/app-nfs-server`), tagged with the app's `version` and `latest`. Each app's `image:` key in
`config.yaml` is the generic manifest name — the Builder derives the per-arch image names (`{arch}-app-<slug>`) from it
and the app's `arch:` list, so the key needs no per-arch maintenance. Pull requests only build without publishing.

[aarch64-shield]: https://img.shields.io/badge/aarch64-yes-green.svg
[amd64-shield]: https://img.shields.io/badge/amd64-yes-green.svg
