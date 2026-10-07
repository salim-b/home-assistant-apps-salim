<!-- https://developers.home-assistant.io/docs/apps/presentation#keeping-a-changelog -->

## 0.2.0

- Fixed startup failure: mount the kernel's `nfsd` filesystem at `/proc/fs/nfsd` (and try to load the `nfsd` kernel module) before configuring NFS versions and shares
- Fixed service definition to match `rpc.nfsd`'s behavior (it configures the in-kernel NFS server and then exits): the service is now an s6-rc `oneshot` instead of a supervised `longrun` with readiness polling that could never succeed
- Narrowed app privileges: replaced `full_access` with `kernel_modules` (maps host kernel modules into the app read-only, grants `SYS_MODULE`) and the `SYS_ADMIN` capability (required for mounting the `nfsd` filesystem)

## 0.1.0

- Initial release