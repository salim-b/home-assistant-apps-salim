# Home Assistant app: NFS Server

## Configuration

NFS shares are configured in the app's options: each **NFS shares** entry exports one directory of the Home Assistant host to a set of allowed clients. An entry consists of the directory's **Path**, the allowed client **Network** and the NFS export **Options** – see the field descriptions in the configuration dialog for details and examples.

Saving the options restarts the app, which then exports the configured shares.

The app keeps no NFS client state across app restarts: after a (re)start the server runs a short grace period (10 seconds by default, configurable via the `grace_time` option) instead of the kernel's 90-second default, so clients' first write attempt after a restart is delayed only briefly.

## Mounting a share

The server only provides NFSv4.x, so mount with `-t nfs4`, using the share's **Path** as the export path. For the default share:

```
mount -t nfs4 homeassistant.local:/share/nfs /mnt/nfs
```

## Requirements

The NFS server runs in the host's kernel: it requires the host kernel to provide the `nfsd` kernel module (`CONFIG_NFSD`). [Home Assistant OS](https://github.com/home-assistant/operating-system) ships this module on Rockchip-based boards (e.g. ODROID-M1/M1S, Home Assistant Green); on other boards the app fails to start with an explanatory error message.

## Filesystem permissions for NFS shares

The NFS server requires appropriate filesystem permissions on shared directories.

- Shares must be **directories** located underneath `/share/` or `/media/` (the mapped roots themselves may be shared too); files cannot be NFS export points, and other paths cannot be exported.

- For new directories: The app will create new directories with the default ownership and permissions configured in the app's options.

- For existing directories: The app will not modify existing permissions. Note that export options like `rw` do not override file permissions: NFS requests are evaluated with the client's effective user/group (after `root_squash` / `all_squash` squashing to `anonuid`/`anongid`), so the shared directory must be readable/writable for those identities (e.g. a directory owned by `root:root` will not be writable by clients squashed to uid/gid `1000`).