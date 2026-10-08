# Development knowledge

Non-obvious facts and gotchas learned while developing this app, collected
here so they don't have to be re-learned the hard way.

## `echo`/`printf` cannot write to `/proc/fs/nfsd/*` (`EINVAL`)

The app base image's bash (5.3.9) implements the output of its `echo` and
`printf` builtins as a single `writev(2)` call, with the text and the
trailing newline as separate iovecs. The kernel's nfsd control files
(`fs/nfsd/nfsctl.c`, `transaction_ops`) only implement the old-style
single-buffer `.write` and no `.write_iter`, and `writev(2)` against such
files fails with `EINVAL` on modern kernels.

Consequences:

- Every `echo`/`printf` redirection into `/proc/fs/nfsd/*` fails with a
  misleading `write error: Invalid argument` – the error is about the syscall
  shape, not the written content (e.g. referencing non-available NFS
  versions is irrelevant here).
- Single-`write(2)` callers succeed: busybox `echo`, `cat`, and `rpc.nfsd`'s
  own writes (which is why `rpc.nfsd` can configure the version set fine).

Workaround, if a direct write to such a kernel file is ever needed: stage the
string in a regular file (e.g. on tmpfs) and `cat` it into the target.

## `rpc.nfsd` is not a daemon

`rpc.nfsd` only configures the NFS server inside the kernel (version set,
sockets, lease/grace time, kernel threads) and then exits – upstream runs it
as a `Type=oneshot` service. That's why the app runs it as an s6-rc `oneshot`
(`up`/`down` scripts in `/etc/s6-overlay/scripts/`): a `longrun` would
restart-loop forever because the process exits immediately, and readiness
polling (`s6-notifyoncheck`) cannot work for a process that is gone.

Consequences for the NFS version set:

- `rpc.nfsd` writes its default version set (NFSv3 and NFSv4) to the kernel
  unless told otherwise – `--no-nfs-version 3` is what keeps this app's
  setup NFSv4-only. The outcome is logged and verified in
  `rootfs/etc/s6-overlay/scripts/nfsd-start`.
- `-N`/`-V` only accept 3 and 4: passing `--no-nfs-version 2` exits with
  `2: Unsupported version` (NFSv2 server support is not compiled into
  current kernels anyway, `CONFIG_NFSD_V2` defaults to off).

## The NFS version set is fixed while the server runs

Once an NFS server instance exists in the kernel (i.e. `rpc.nfsd` started
it), writes to `/proc/fs/nfsd/versions` fail with `EBUSY`, and further
`rpc.nfsd` invocations only adjust the thread count anymore (version/socket
configuration is skipped). Stop the threads with `rpc.nfsd 0` first to
reconfigure.

Within a running container the version set lives in the kernel's network
namespace: it survives s6 service restarts and is only reset to the kernel
defaults (everything compiled-in: `+3 +4 +4.1 +4.2`) when the container –
and with it the network namespace – is recreated.
