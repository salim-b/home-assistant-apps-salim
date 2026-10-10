# Home Assistant app: NFS Server

## Configuration

NFS shares are configured in the app's options: each **NFS shares** entry exports one directory of the Home Assistant host to a set of allowed clients. An entry consists of the directory's **Path**, the allowed client **Network** and the NFS export **Options** – see the field descriptions in the configuration dialog for details and examples.

Saving the options restarts the app, which then exports the configured shares.

## NFSv4 client state recovery

The app runs the kernel's client-recovery tracker (`nfsdcld`, with a persistent sqlite store in the app's data directory), so NFSv4 clients that are connected across an app (re)start keep their state – open files, byte-range locks and delegations: they reclaim it from the tracker's records during the grace period that follows the restart, instead of losing it. Held locks surviving an app update/restart are the visible effect.

The grace period only runs when there is client state to reclaim: after a boot with no recorded clients the server skips it entirely, and it ends early once all recorded clients have reclaimed. The `grace_time` option (if set) overrides the default, which matches the `lease_time` option (keep it at or above `lease_time` so idle clients – whose state-manager renewals fire at ~lease/3 intervals – can still recover).

## Mounting a share

The server only provides NFSv4.x, so mount with `-t nfs4`, using the share's **Path** as the export path. For the default share:

```
mount -t nfs4 homeassistant.local:/share/nfs /mnt/nfs
```

## Security notes

- **Authentication**: NFSv4 with `sec=sys` (the default here) has no cryptographic authentication – a client's claimed user ID is taken at face value. Anyone on an allowed network can connect as any user ID; treat only trusted networks as allowed clients.
- **Access control**: the `network` option of each share is the only access control (plus the port being published on **all** host interfaces by the container runtime – restricting reachability to the intended LAN is a router/firewall concern). Prefer listing specific networks over `*` (all clients).
- **Read-only by default**: exports without `rw` in their options are read-only. For shares that only need to be read (e.g. media), omit `rw`.
- **User identity mapping**: by default, requests from user ID `0` (root) are squashed to the anonymous user (`anonuid`/`anongid`, here `1000`) – see the option descriptions in the configuration dialog.

## Requirements

The NFS server runs in the host's kernel: it requires the host kernel to provide the `nfsd` kernel module (`CONFIG_NFSD`). [Home Assistant OS](https://github.com/home-assistant/operating-system) ships this module on Rockchip-based boards (e.g. ODROID-M1/M1S, Home Assistant Green); on other boards the app fails to start with an explanatory error message.

## Filesystem permissions for NFS shares

The NFS server requires appropriate filesystem permissions on shared directories.

- Shares must be **directories** located underneath `/share/` or `/media/` (the mapped roots themselves may be shared too); files cannot be NFS export points, and other paths cannot be exported.

- For new directories: The app will create new directories with the default ownership and permissions configured in the app's options.

- For existing directories: The app will not modify existing permissions. Note that export options like `rw` do not override file permissions: NFS requests are evaluated with the client's effective user/group (after `root_squash` / `all_squash` squashing to `anonuid`/`anongid`), so the shared directory must be readable/writable for those identities (e.g. a directory owned by `root:root` will not be writable by clients squashed to uid/gid `1000`).
