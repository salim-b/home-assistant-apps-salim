<!-- https://developers.home-assistant.io/docs/apps/presentation#keeping-a-changelog -->

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
