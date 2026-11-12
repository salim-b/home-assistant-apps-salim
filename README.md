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
AppArmor, base-image gotchas, testing) and in each app's own `KNOWLEDGE.md`; step-by-step procedures live in the skills
under [`.agents/skills/`](./.agents/skills) (index in [`AGENTS.md`](./AGENTS.md)).

### Setup

We use [mise](https://mise.jdx.dev/) as tool and environment manager and task runner. Bootstrap the pinned toolchain:

```sh
mise trust               # first use: mise config files are untrusted until then
mise install --locked    # pinned tools from mise.toml/mise.lock
```

`docker` is additionally required for the `build`, `test:lab`, `deploy:local`/`deploy:registry` and `test:live` tasks.

### Common tasks

`mise run <task> --help` provides the full, current usage instructions for any task; `mise tasks ls --local` lists them.
The most common ones:

```sh
# check and validate files (the same lint/validate gate CI runs)
mise run check

# test app in a containerized lab
mise run test:lab nfs-server

# deploy app to HAOS device (installed as a local app)
mise run deploy:local nfs-server root@homeassistant.local

# switch a device from the locally installed app to the published registry version,
# migrating app options
mise run deploy:registry hd-idle root@homeassistant.local --config migrate

# apply a JSON options file to the installed app on the device
# (schema-filtered, previous options backed up; see `mise run apply-options --help`)
mise run apply-options hd-idle root@homeassistant.local options.json

# get app logs from HAOS device (`--follow` continuously prints new log entries until
# you abort; app slug is `local_<config.yaml slug>`)
ssh root@homeassistant.local 'ha apps logs --follow local_nfs-server'
```

### Testing on a device

`mise run test:live` deploys the app to a real HAOS device as a local app (like `deploy:local`, forwarding `--replace`)
and then runs an end-to-end test against it — for the `nfs-server` app, this includes an NFS client roundtrip against
the running app. With `--test-options`, the repo's test options are applied for the run only, with the device app's own
options backed up and restored automatically:

```sh
# plain: tests the device app's currently configured shares
mise run test:live nfs-server root@homeassistant.local

# with the repo's test options applied for the run (a minimal set exercising
# the whole export surface: default share, read-only share, /media share,
# nested path, second client network)
mise run test:live nfs-server root@homeassistant.local --test-options
```

Deploy-task mechanics that are not visible in `--help` — why the device-side app config's `image:` key gets commented
out, and what happens when the app is also installed from the app repository — are documented in [`KNOWLEDGE.md`
§"Deploy tasks: local builds and store-copy
conflicts"](KNOWLEDGE.md#deploy-tasks-local-builds-and-store-copy-conflicts).

## CI

On every push to `main`, the [Builder](./.github/workflows/builder.yaml) workflow builds each app whose relevant files
changed and publishes its container images to GHCR via the [Build app](./.github/workflows/build-app.yaml) workflow:
per-arch images (e.g. `ghcr.io/salim-b/amd64-app-nfs-server`) plus a multi-arch manifest (e.g.
`ghcr.io/salim-b/app-nfs-server`), tagged with the app's `version` and `latest`. Each app's `image:` key in
`config.yaml` is the generic manifest name — the Builder derives the per-arch image names (`{arch}-app-<slug>`) from it
and the app's `arch:` list, so the key needs no per-arch maintenance. Pull requests only build without publishing.

[aarch64-shield]: https://img.shields.io/badge/aarch64-yes-green.svg
[amd64-shield]: https://img.shields.io/badge/amd64-yes-green.svg
