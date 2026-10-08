# TODOs

- ~~The host's kernel doesn't include the `nfsd` kernel module and hence the container can't load that module.~~

  **Resolved:** the app mounts the `nfsd` filesystem on startup (which also autoloads the `nfsd` kernel module on hosts that ship it). It turns out Home Assistant OS already includes the module (`CONFIG_NFSD=m`) for Rockchip-based boards (ODROID-M1/M1S, Home Assistant Green) – verified for HAOS 18.3. On all other boards (e.g. Raspberry Pi, x86_64), the HAOS kernels lack `CONFIG_NFSD` entirely, so the app cannot work there. Follow-up: suggest enabling `CONFIG_NFSD=m` for all HAOS kernels upstream in the [Home Assistant OS repo](https://github.com/home-assistant/operating-system) (the NFS *client* `CONFIG_NFS_FS` is already built into all of them).

- We currently set `apparmor: false` to fully disable [AppArmor](https://developers.home-assistant.io/docs/apps/presentation/#apparmor) for testing. Instead, we should try `apparmor: true` with HA's default profile (i.e. removing our custom `apparmor.txt` file, or replacing it with the default one, not sure). If that works, try to improve on the default profile. If not, try starting from our current custom profile (likely only works with a lot more relaxed restrictions) – it must at least allow mounting the `nfsd` filesystem and running `rpc.nfsd`/`exportfs`.

- We now grant the `SYS_ADMIN` capability (required for mounting the `nfsd` filesystem) in addition to the `SYS_MODULE` capability that comes with `kernel_modules: true`. If an AppArmor profile ever allows enough, check whether the mount can be moved out of the app (e.g. via a HAOS-side `proc-fs-nfsd.mount` unit) so that even `SYS_ADMIN` is no longer needed.

- Create upstream PR in HA to render app configuration labels in the UI as Markdown blocks instead of the current single-line plain text.

