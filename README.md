# Salim B's Home Assistant apps

This repository holds [@salim-b](https://github.com/salim-b)'s [Home Assistant apps](https://www.home-assistant.io/getting-started/concepts-terminology/#apps).

[![Open your Home Assistant instance and show the <kbd>Add app repository?</kbd> dialog with Salim B's repository URL pre-filled.](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fsalim-b%2Fhome-assistant-apps-salim)

## Apps

### [NFS Server](./nfs-server)

![Supports aarch64 Architecture][aarch64-shield]
![Supports amd64 Architecture][amd64-shield]

Turn your Home Assistant instance into a [Network File System (NFS)](https://en.wikipedia.org/wiki/Network_File_System) server.

## Development

The structure of all apps in this repository follows Home Assistant's [best practices](https://developers.home-assistant.io/docs/apps) as far as possible.

To test an app on your Home Assistant server (device), use the `deploy` mise task. It copies the app folder to the device's `/local_apps/` directory (removing an existing copy first), refreshes the app store metadata, then installs the app (if not present), updates it (if the version changed in `config.yaml`) or rebuilds its image (otherwise), and makes sure it is running afterwards.

Note that the task comments out the top-level `image:` key in the *device-side* copy of `config.yaml`: with an `image` key set, the Supervisor would pull that image from GHCR instead of building locally from your working tree — see the [dev docs](https://developers.home-assistant.io/docs/add-ons/testing/#remote-development).

If the app is already installed on the device **from an app repository** (i.e. not as a local app — such installs have a hashed store slug like `f8b2d53d_nfs`), the task refuses: a second installation would conflict on the app's published port. Uninstall that copy first (the error message shows the exact command) or pass `--replace` to have the task uninstall it automatically.

For a full end-to-end test including an NFS client roundtrip against the running app, run:

```sh
# plain: tests the device app's currently configured shares
mise run test:live nfs-server root@192.168.1.11

# with the repo's test options applied for the run (a minimal set exercising
# the whole export surface: default share, read-only share, /media share,
# nested path, second client network — your app options are backed up and
# restored automatically)
mise run test:live nfs-server root@192.168.1.11 --test-options
```

It deploys (forwarding `--replace`/`--test-options`) and then mounts each configured share from this machine — write + read-back + delete on writable shares, a read-only assertion on `ro` shares, and a pseudo-root browse check — cleaning up after itself.

To deploy the `nfs-server` app, for example, run:

```sh
# app name (repo subfolder) + SSH target of the device
mise run deploy nfs-server root@192.168.1.11

# get app logs (`--follow` continuously prints new log entries until you abort;
# app slug is `local_<config.yaml slug>`)
ssh root@192.168.1.11 'ha apps logs --follow local_nfs'
```

## CI

On every push to `main`, the [Builder](./.github/workflows/builder.yaml) workflow builds each app whose relevant files changed and publishes its container images to GHCR via the [Build app](./.github/workflows/build-app.yaml) workflow: per-arch images (e.g. `ghcr.io/salim-b/amd64-app-nfs-server`) plus a multi-arch manifest (e.g. `ghcr.io/salim-b/app-nfs-server`), tagged with the app's `version` and `latest`. Pull requests only build without publishing.

[aarch64-shield]: https://img.shields.io/badge/aarch64-yes-green.svg
[amd64-shield]: https://img.shields.io/badge/amd64-yes-green.svg
