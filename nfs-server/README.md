# Home Assistant app: NFS Server

Turn your Home Assistant instance into a [Network File System (NFS)](https://en.wikipedia.org/wiki/Network_File_System)
server.

![Supports aarch64 Architecture][aarch64-shield] ![Supports amd64 Architecture][amd64-shield]

## Features

- **NFSv4 server**: Runs the Linux kernel's own NFS server (`nfsd`) in the host's kernel – the same implementation as on
  a native Linux file server, not a userspace daemon inside the app container.
- **Configurable shares**: Each share entry exports one directory of the Home Assistant host to one set of allowed
  clients with its own export options ([`exports(5)`](https://man.cx/exports(5)) syntax). The same directory may be
  exported to different networks with different options. Entries are validated in the configuration dialog and again at
  startup.
- **Client state recovery**: NFSv4 clients that are connected across an app restart or update keep their state – open
  files, byte-range locks and delegations – and reclaim it from the tracker's records during the grace period that
  follows. The tracker (`nfsdcld`) keeps its persistent state in the app's data directory, and the grace period is
  skipped entirely when there is nothing to recover.
- **Hardened runtime**: Ships a custom [AppArmor](https://apparmor.net/) profile that restricts mounts and capabilities
  to what the server needs.

## Limitations

- **Requires kernel support**: The host kernel must provide the `nfsd` kernel module (`CONFIG_NFSD`). [Home Assistant
  OS](https://github.com/home-assistant/operating-system) ships it on the ODROID-M1/M1S, Home Assistant Green, Raspberry
  Pi 3/4/5 and Home Assistant Yellow boards — not yet on the generic/OVA images and ODROID-C2/C4/N2 and Khadas VIM3
  ([upstream proposal](https://github.com/orgs/home-assistant/discussions/5334)); on boards without the module the app
  fails to start with an explanatory error message.
- **NFSv4+ only**: The app serves the [NFSv4+](https://en.wikipedia.org/wiki/Network_File_System#NFSv4) protocol; NFSv2
  and NFSv3 clients cannot connect. Mount with `-t nfs4`.
- **Network-level access control only**: No cryptographic authentication (`sec=sys`) – a client's claimed user ID is
  taken at face value. The allowed client networks of each share are the only access control, and the NFS port is
  published on all host interfaces (restricting reachability is a router/firewall concern).

## Documentation

For usage, configuration, security notes and client mounting instructions, see the
[**Documentation**](/config/app/f8b2d53d_nfs-server/documentation).

[aarch64-shield]: https://img.shields.io/badge/aarch64-yes-green.svg
[amd64-shield]: https://img.shields.io/badge/amd64-yes-green.svg
