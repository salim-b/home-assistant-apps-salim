#!/usr/bin/env bash
#MISE hide=true
#MISE description="⚠️ internal helper script"
# App hook for .mise/tasks/lab.sh (nfs-server specifics).
#
# Contract: this file may set
# - lab_docker_args   : APPEND to this array (lab_docker_args+=(...)) for the
#                       app container's docker run (volumes, capabilities,
#                       devices; --privileged/--network and /data are
#                       provided by the harness)
# - lab_fixture_py    : path (relative to the app dir) of a python file
#                       defining lab_adapt_fixture(options)->options, served
#                       by the fake supervisor API (omit: raw config options)
# and may define
# - lab_runtime_check : function running the app's runtime roundtrip
#                       (runs after boot, before the graceful stop).
#
# shellcheck disable=SC2034  # contract variables are consumed by the harness

## Privileged mounts (nfsd filesystem, per-share bind mirrors); share/media
## stand-ins like on a real device
lab_docker_args+=(
  -v "$LAB_TMPDIR/share:/share"
  -v "$LAB_TMPDIR/media:/media"
)

## Fixture adaptation: every share's client network must point at the lab
## subnet for the roundtrip to be allowed
lab_fixture_py="lab-fixture.py"

lab_runtime_check() {
  ## Client-recovery tracker (cld): the daemon must be up with its sqlite
  ## store on /data and the kernel must have created the upcall pipe in the
  ## container's rpc_pipefs instance; "Using nfsdcld client tracking
  ## operations" in the kernel log is the end-to-end proof (the kernel only
  ## logs it after the daemon answered its GetVersion + GraceStart upcalls).
  ## Fresh /data => no records => the kernel's skip-grace path must show too.
  if ! docker exec "$LAB_NET_NAME-app" sh -c '
      ps | grep -q "[n]fsdcld" &&
      test -f /data/nfsdcld/main.sqlite &&
      test -p /var/lib/nfs/rpc_pipefs/nfsd/cld'; then
    echo "recovery tracker not fully up (nfsdcld process / sqlite store / upcall pipe)"
    return 1
  fi
  klog=$(docker exec "$LAB_NET_NAME-app" dmesg 2>/dev/null | grep "NFSD:" | tail -5)
  grep -q "Using nfsdcld client tracking operations" <<<"$klog" \
    || { echo "kernel did not use the cld tracker; NFSD log tail: $klog"; return 1; }
  grep -q "no clients to reclaim, skipping NFSv4 grace period" <<<"$klog" \
    || { echo "expected the skip-grace path (fresh /data, no records); NFSD log tail: $klog"; return 1; }
  echo "recovery tracker up (nfsdcld, sqlite on /data, kernel upcalls + skip-grace OK)"

  echo "host-file" > "$LAB_TMPDIR/share/nfs/hostfile.txt" 2>/dev/null \
    || { mkdir -p "$LAB_TMPDIR/share/nfs" && echo "host-file" > "$LAB_TMPDIR/share/nfs/hostfile.txt"; }
  docker rm -f "$LAB_NET_NAME-client" >/dev/null 2>&1 || true
  if ! docker run --rm --privileged --name "$LAB_NET_NAME-client" --network "$LAB_NET_NAME" \
    local/nfslab-client:alpine3.24 sh -c "
    mkdir -p /mnt/test
    mount -t nfs4 '$LAB_APP_IP:/share/nfs' /mnt/test || exit 10
    grep -q 'host-file' /mnt/test/hostfile.txt || exit 11
    echo client-write > /mnt/test/client.txt || exit 12
    sync"; then
    echo "NFS roundtrip failed (rc=$?)"
    return 1
  fi
  if ! grep -q "client-write" "$LAB_TMPDIR/share/nfs/client.txt"; then
    echo "client write did not reach the host filesystem"
    return 1
  fi
  echo "NFS roundtrip OK (rw write reached the host filesystem)"
}
