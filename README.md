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

To test an app locally on your Home Assistant server, stop a possibly running instance of that app and copy the app's subfolder in this repository to the `/local_apps/` directory of Home Assistant, e.g. via SSH. Then, either update the app (if you bumped its version) or otherwise trigger an app rebuild.

To test the `nfs-server` app for example, run:

```sh
# remove possibly existing obsolete app files
ssh root@homeassistant.local 'rm -rf /local_apps/nfs-server'

# copy the latest app files
scp -r nfs-server root@homeassistant.local:/local_apps/

# reload app metadata
ssh root@homeassistant.local 'ha store reload'

# IF VERSION IS INCREASED: update app
ssh root@homeassistant.local 'ha apps update local_nfs'
# OTHERWISE: rebuild app container
ssh root@homeassistant.local 'ha apps rebuild local_nfs'

# restart app
ssh root@homeassistant.local 'ha apps restart local_nfs'

# get app logs (`--follow` continuously prints new log entries until you abort)
ssh root@homeassistant.local 'ha apps logs --follow local_nfs'
```

## CI

On every push to `main`, the [Builder](./.github/workflows/builder.yaml) workflow builds each app whose relevant files changed and publishes its container images to GHCR via the [Build app](./.github/workflows/build-app.yaml) workflow: per-arch images (e.g. `ghcr.io/salim-b/amd64-app-nfs-server`) plus a multi-arch manifest (e.g. `ghcr.io/salim-b/app-nfs-server`), tagged with the app's `version` and `latest`. Pull requests only build without publishing.

[aarch64-shield]: https://img.shields.io/badge/aarch64-yes-green.svg
[amd64-shield]: https://img.shields.io/badge/amd64-yes-green.svg
