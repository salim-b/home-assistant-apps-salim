# Home Assistant app: NFS Server

Turn your Home Assistant instance into a [Network File System (NFS)](https://en.wikipedia.org/wiki/Network_File_System) server: it exports directories of the Home Assistant host so that other machines can mount them.

![Supports aarch64 Architecture][aarch64-shield]
![Supports amd64 Architecture][amd64-shield]

## Features

- **NFSv4 server**: runs the Linux kernel's own NFS server (`nfsd`) in the host's kernel – the same implementation as on a native Linux file server, not a userspace daemon inside the app container.
- **Configurable shares**: each share entry exports one directory of the host to one set of allowed clients with its own export options (`exports(5)` syntax); the same directory may be exported to different networks with different options. Entries are validated in the configuration dialog and again at startup.
- **Client state recovery**: NFSv4 clients that are connected across an app restart or update keep their state – open files, byte-range locks and delegations – and reclaim it from the tracker's records during the grace period that follows. The tracker (`nfsdcld`) keeps its persistent state in the app's data directory, and the grace period is skipped entirely when there is nothing to recover.
- **Hardened runtime**: ships a custom AppArmor profile that restricts mounts and capabilities to what the server needs.

## Limitations

- **Requires kernel support**: the host kernel must provide the `nfsd` kernel module (`CONFIG_NFSD`). [Home Assistant OS](https://github.com/home-assistant/operating-system) ships it on Rockchip-based boards (e.g. ODROID-M1/M1S, Home Assistant Green); on other boards the app fails to start with an explanatory error message.
- **NFSv4+ only**: the app serves the [NFSv4+](https://en.wikipedia.org/wiki/Network_File_System#NFSv4) protocol; NFSv2 and NFSv3 clients cannot connect. Mount with `-t nfs4`.
- **Network-level access control only**: the default security flavor (`sec=sys`) performs no cryptographic authentication – a client's claimed user ID is taken at face value. The allowed client networks of each share are the only access control, and the NFS port is published on all host interfaces; only allow trusted networks, and keep reachability restricted to them (a router/firewall concern).
- **Read-only by default**: exports are read-only unless a share's options include `rw`.

## Documentation

Usage, configuration, security notes and client mounting instructions: see the **Documentation** tab on the app's page ([`DOCS.md`](./DOCS.md) in the repository).

[aarch64-shield]: https://img.shields.io/badge/aarch64-yes-green.svg
[amd64-shield]: https://img.shields.io/badge/amd64-yes-green.svg