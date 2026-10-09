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

## The app needs host kernel modules and privileged mounts; share/media
## stand-ins like on a real device
lab_docker_args+=(
  -v /lib/modules:/lib/modules:ro
  -v "$LAB_TMPDIR/share:/share"
  -v "$LAB_TMPDIR/media:/media"
)

## Fixture adaptation: every share's client network must point at the lab
## subnet for the roundtrip to be allowed
lab_fixture_py="lab-fixture.py"

lab_runtime_check() {
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
