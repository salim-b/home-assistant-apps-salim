<!-- https://developers.home-assistant.io/docs/apps/presentation#keeping-a-changelog -->

## 0.4.2

- Temporary diagnostic release (AppArmor iteration): blanket `mount` rule plus
  confinement/capability logging around the nfsd mount, to pinpoint which
  layer denies the mount. Will be tightened in the next release.
## 0.4.1

- Fix the AppArmor profile so the app can start again: allow mounting the nfsd
  filesystem (the device string `nfsd` is the mount source, so the rule is
  scoped by filesystem type), the per-share `mount --bind` mirrors and their
  unmount; drop unproven raw-network rules from the rpc.nfsd sub-profile.
## 0.4.0

- AppArmor support: ships a custom, much tightened AppArmor profile (per-app sub-profiles for `exportfs`, `rpc.nfsd` and `rpc.mountd`; mount restricted to the `nfsd` filesystem type; no more blanket `full` rules) – the app now runs with `apparmor: true` instead of AppArmor disabled
- ⚠️ Note for this release: the profile is new and was validated statically (parser + rule-coverage analysis) but not yet enforced on a device; if the app fails to start with permission denials, please report the log output

## 0.3.3

- Share configuration is now validated in the UI with regex constraints: share paths must be clean absolute paths under `/share` or `/media`, and the client network and export options must not contain whitespace or parentheses (defense in depth against malformed `/etc/exports` entries; see the option descriptions in the configuration dialog)
- Default share options no longer enable `async` (synchronous writes are the `exports(5)` default and much safer against data loss on crash; `async` remains available per share)
- New "Security notes" section in the documentation (authentication, access control, read-only defaults, identity mapping)

## 0.3.2

- Fixed clients' first write attempt after an app (re)start stalling for ~90 seconds: the server now always starts with a short grace period (10 seconds by default instead of the kernel's 90; configurable via the `grace_time` option) – the full-length grace only protects client state recovery, which the containerized server cannot provide (see the app's source repository knowledge file for details)

## 0.3.1

- Migrated to the current s6-overlay layout: the user bundle is now declared in `/etc/s6-overlay/user-bundles.d/user/contents.d/` (service definitions stay in `/etc/s6-overlay/s6-rc.d/`), removing the "defining user bundles in /etc/s6-overlay/s6-rc.d is deprecated" startup warning

## 0.3.0

- Fixed NFSv4 client mounts hanging forever: the kernel's nfsd resolves NFSv4 paths via export-cache upcalls that are serviced by `rpc.mountd` – the app now runs a `mountd` service (no network ports, legacy MOUNT protocol disabled)
- Fixed NFSv4 path resolution: the pseudo file system root now lives on the app's persistent `/data` volume (`/data/pseudo_root`, per-share bind mounts), as the container's root filesystem cannot be exported; client paths are unchanged (`host:/share/nfs`, …) and per-share options are now actually enforced
- Shares are exported with distinct numeric `fsid`s to keep the filehandle mapping unambiguous across the bind-mounted exports; the pseudo file system root itself is exported read-only without `crossmnt` (an NFSv3-only flag)
- Shares must be clean absolute directories (no empty path components); whitespace in share path/network/options is rejected with an explanatory error
- The default share options no longer enable `pnfs` (no benefit with a single server)
- Note: NFSv4 client state recovery after server restarts is not available for the containerized server (the kernel refuses the legacy/upcall-helper tracking outside the host's network namespace; see `KNOWLEDGE.md`) – fresh mounts and writes are unaffected

## 0.2.7

- No functional changes: comment cleanup, app design notes moved to the repository's `KNOWLEDGE.md`

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
