# Home Assistant app: NFS Server

## Configuration

NFS shares are configured in the app's [settings](/config/app/f8b2d53d_nfs-server/config): Each **NFS shares** entry
exports one directory of the Home Assistant host to a set of allowed clients. An entry consists of the directory's
**Path**, the allowed client **Network** and the NFS export **Options** – see the field descriptions in the
configuration dialog for details and examples.

Saving configuration changes restarts the app, which then exports the configured shares.

Duplicate entries (the same path and network configured more than once) are rejected at startup with an explanatory
message: one option set applies per path and network pair. The same path with different networks is valid – it exports
the directory with different options per network.

## Mounting a share

The server only provides NFSv4.x, so mount with `-t nfs4`, using the share's **Path** as the export path. For the
default share:

```sh
mount -t nfs4 homeassistant.local:/share/nfs /mnt/nfs
```

For read-only access to all configured shares at once (under a single parent), mount the NFS pseudo-filesystem root:

```sh
mount -t nfs4 homeassistant.local:/ /mnt/nfs
```

## Filesystem permissions for NFS shares

The NFS server requires appropriate filesystem permissions on shared directories.

- Shares must be **directories** located underneath `/share/` or `/media/` (the mapped roots themselves may be shared
  too); files cannot be NFS export points, and other paths cannot be exported.

- For new directories: The app will create new directories with the default ownership and permissions configured in the
  app's settings.

- For existing directories: The app will not modify existing permissions. Note that export options like `rw` do not
  override file permissions: NFS requests are evaluated with the client's effective user/group (after `root_squash` /
  `all_squash` squashing to `anonuid`/`anongid`), so the shared directory must be readable/writable for those identities
  (e.g. a directory owned by `root:root` will not be writable by clients squashed to uid/gid `1000`).

## NFSv4 client state recovery

The app runs the kernel's client-recovery tracker (`nfsdcld`, with a persistent SQLite store in the app's data
directory), so clients that are connected across an app (re)start keep their state – open files, byte-range locks and
delegations: they reclaim it from the tracker's records during the grace period that follows the restart, instead of
losing it. Held locks surviving an app update/restart are the visible effect.

The grace period only runs when there is client state to reclaim: after a boot with no recorded clients the server skips
it entirely, and it ends early once all recorded clients have reclaimed. The `grace_time` option (if set) overrides the
default, which matches the `lease_time` option (keep it at or above `lease_time` so idle clients – whose state-manager
renewals fire at ~lease/3 intervals – can still recover).

## Automatic drive remount handling

Drives behind NFS shares (typically USB disks mounted under `/media/`) can be unplugged and replugged while the app is
running. The app watches its configured share paths for such mount changes and recovers on its own – no manual app
restart needed:

- **Drive replugged** (same or different device name, mounted at the same path): within about 30 seconds the affected
  shares serve the drive's current content again. The watcher refreshes the export configuration and restarts the NFS
  server; connected clients keep working across this via the NFSv4 state recovery described above.
- **Drive unplugged**: the affected shares temporarily export an empty directory. The app never serves stale data from
  the detached drive's filesystem, so once the drive is gone the old files are no longer reachable over NFS. A tick
  message in the log notes the event; when the drive comes back the shares recover as above.

If a share path no longer resolves to a mount at all (the directory is missing rather than just unmounted), the app
exports an empty directory for it until the path reappears.

## Security notes

- **Authentication**: NFSv4 with `sec=sys` has no cryptographic authentication – a client's claimed user ID is taken at
  face value. Anyone on an allowed network can connect as any user ID, therefore it's essential to allow only trusted
  networks.
- **Access control**: The `network` option of each share is the only access control (plus the port being published on
  **all** host interfaces by the container runtime – restricting reachability to the intended LAN is a router/firewall
  concern). Prefer listing specific networks over `*` (all clients).
- **Read-only by default**: Exports without `rw` in their options are read-only. For shares that only need to be read
  (e.g. media), omit `rw`.
- **User identity mapping**: By default, requests from user ID `0` (root) are squashed to the anonymous user defined via
  `anonuid` and `anongid` (default `65534`) – see the option descriptions in the configuration dialog.

## Requirements

The NFS server runs in the host's kernel: it requires the host kernel to provide the `nfsd` kernel module
(`CONFIG_NFSD`). [Home Assistant OS](https://github.com/home-assistant/operating-system) ships this module on
Rockchip-based boards (e.g. ODROID-M1/M1S, Home Assistant Green); on other boards the app fails to start with an
explanatory error message.
