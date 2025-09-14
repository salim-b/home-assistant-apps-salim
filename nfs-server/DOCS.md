# Home Assistant app: NFS Server

## How to use

TODO

## Filesystem permissions for NFS shares

The NFS server requires appropriate filesystem permissions on shared directories.

- For new directories: The app will create new directories with default permissions (`755`, `root:root`). These can be adjusted in the app's configuration.

- For existing directories: The app will not modify existing permissions, hence users must ensure the NFS server (running as `root`) has read and execute permissions (plus write permission for `rw` shares) to the paths to be shared via NFS.
