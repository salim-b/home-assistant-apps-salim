# Salim B's Home Assistant app repository

This repository holds [@salim-b](https://github.com/salim-b)'s [Home Assistant apps](https://www.home-assistant.io/getting-started/concepts-terminology/#apps).

[![Open your Home Assistant instance and show the <kbd>Add app repository?</kbd> dialog with Salim B's repository URL pre-filled.](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fsalim-b%2Fhome-assistant-apps-salim)

## Apps

### [NFS Server](./nfs-server)

![Supports aarch64 Architecture][aarch64-shield]
![Supports amd64 Architecture][amd64-shield]

Turn your Home Assistant instance into a [Network File System (NFS)](https://en.wikipedia.org/wiki/Network_File_System) server.

## Development

The structure of all apps in this repository follows Home Assistant's [best practices](https://developers.home-assistant.io/docs/apps) as much as possible.

To test an app locally on your Home Assistant server, stop a possibly running instance of that app and copy the app's subfolder in this repository to the `/local_apps/` directory of Home Assistant, e.g. via SSH. To test the `nfs-server` app for example, run:

```sh
# remove possibly existing obsolete app files
ssh root@homeassistant.local 'rm -rf /local_apps/nfs-server'

# copy the latest app files
scp -r nfs-server root@homeassistant.local:/local_apps/

# reload app metadata, rebuild app container and restart app
ssh root@homeassistant.local 'ha store reload && ha apps rebuild local_nfs && ha apps restart local_nfs'
```

<!--

Notes to developers after forking or using the github template feature:
- While developing comment out the 'image' key from 'example/config.yaml' to make the supervisor build the app locally.
  - Remember to put this back when pushing up your changes.
- When you merge to the 'main' branch of your repository a new build will be triggered.
  - Make sure you adjust the 'version' key in 'example/config.yaml' when you do that.
  - Make sure you update 'example/CHANGELOG.md' when you do that.
  - The first time this runs you might need to adjust the image configuration on github container registry to make it public.
  - You may also need to adjust the GitHub Actions configuration (Settings > Actions > General > Workflow > Read & Write).
- Update the repository check in '.github/workflows/build-app.yaml' to match your repository name
  (the 'github.repository' condition in the 'prepare' job).
- Adjust the 'image' key in 'example/config.yaml' so it points to your username instead of 'home-assistant'
  (e.g., 'ghcr.io/my-username/my-app').
- Rename the example directory.
  - The 'slug' key in 'example/config.yaml' should match the directory name.
- Adjust all keys/urls that point to 'home-assistant' to now point to your user/fork.
- Share your repository on the forums https://community.home-assistant.io/c/projects/9
 -->

[aarch64-shield]: https://img.shields.io/badge/aarch64-yes-green.svg
[amd64-shield]: https://img.shields.io/badge/amd64-yes-green.svg
