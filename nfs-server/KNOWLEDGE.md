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
