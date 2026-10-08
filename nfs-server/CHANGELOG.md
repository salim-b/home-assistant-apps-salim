<!-- https://developers.home-assistant.io/docs/apps/presentation#keeping-a-changelog -->

## 0.2.6

- Share paths are now validated at startup: paths outside of `/share/` or `/media/` abort the app with an explanatory error (unmapped paths can never work and nonexistent ones would silently be created in the app's ephemeral filesystem)
- Removed pointless in-container permission checks on shared directories (the container runs as root, so they could never fire) – see `DOCS.md` for the permissions that actually matter (the client-side ones)

## 0.2.5

- Fixed the configuration option labels/descriptions in the UI: the translations file did not parse as YAML at all (a `: ` inside a plain scalar string), the port label key used the wrong case (`2049/TCP` instead of `2049/tcp`) and the `shares` sub-option labels were nested at the wrong level (they must live under the option's `fields` key)

## 0.2.4

- Fixed the CI image build: the Dockerfile no longer relies on the `BUILD_FROM` build argument being provided by the builder actions (it isn't anymore), instead the base image (`ghcr.io/home-assistant/base`, multi-arch manifest) is pinned in the Dockerfile; the deprecated `build.yaml` was removed (base image, build arguments and labels now live in the Dockerfile, architectures are taken from `arch` in `config.yaml`)

## 0.2.3

- Removed the redundant kernel-level NFS version configuration from the startup script: `rpc.nfsd` configures the kernel's version set itself (and the shell's `echo`/`printf` in the app image can't write to `/proc/fs/nfsd` files anyway, as they issue a `writev(2)` which those files reject with `EINVAL` – that's what the misleading "Invalid argument" error was about)
- The NFS versions now get verified and logged after server start

## 0.2.2

- The app image is now built and published to `ghcr.io/salim-b/app-nfs-server` on CI: installing the app from the repository uses the prebuilt image instead of building it locally (local apps under `/local_apps/` are still always built locally)

## 0.2.1

- Fixed the kernel-level NFS version configuration: kernels may reject version writes that reference non-available versions with `EINVAL` instead of ignoring them; only the versions the kernel actually offers are disabled now, and the outcome is verified
- Replaced the obsolete `watchdog` option with a native Docker `HEALTHCHECK`

## 0.2.0

- Fixed startup failure: mount the kernel's `nfsd` filesystem at `/proc/fs/nfsd` (and try to load the `nfsd` kernel module) before configuring NFS versions and shares
- Fixed service definition to match `rpc.nfsd`'s behavior (it configures the in-kernel NFS server and then exits): the service is now an s6-rc `oneshot` instead of a supervised `longrun` with readiness polling that could never succeed
- Narrowed app privileges: replaced `full_access` with `kernel_modules` (maps host kernel modules into the app read-only, grants `SYS_MODULE`) and the `SYS_ADMIN` capability (required for mounting the `nfsd` filesystem)
- Disabled deprecated `armhf`, `armv7` and `i386` architectures.

## 0.1.0

- Initial release
