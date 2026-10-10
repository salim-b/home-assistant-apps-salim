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
# - lab_fixture_py    : path (relative to the repo root; typically
#                       .mise/tasks/lab/<app>.py) of a python file defining
#                       lab_adapt_fixture(options)->options, served by the
#                       fake supervisor API (omit: raw config options)
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
lab_fixture_py=".mise/tasks/lab/nfs-server.py"

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

  ## Client-state reclaim across an app restart (the recovery tracker's
  ## actual feature): hold an exclusive flock from a dedicated client,
  ## restart the app container (fresh netns, sqlite store on /data
  ## persists) and verify the held state survives. Catches the tracker
  ## regressions a plain boot cannot: a broken store path or missing record
  ## persistence fails only the ACROSS-RESTART property, while boot, boot
  ## log and roundtrip all still pass. The lease override in the fixture
  ## adapter (.mise/tasks/lab/nfs-server.py)
  ## (90 s) keeps the recovery detection fast (~lease/3 renewal cycle).
  if ! (
    reclaim="$LAB_NET_NAME-reclaim"
    trap 'docker rm -f "$reclaim" >/dev/null 2>&1 || true' EXIT
    docker run -d --privileged --name "$reclaim" --network "$LAB_NET_NAME" \
      local/nfslab-client:alpine3.24 sleep infinity >/dev/null
    # Holder: open + exclusive flock + periodic writes through the held fd
    # (the tick writes drive the client's recovery: a write on the stale
    # open triggers the reclaim; the server-side file growth is the
    # recovery-landed signal - client-side stat/mountstats lie from the
    # page cache)
    docker exec -d "$reclaim" sh -c '
      mkdir -p /mnt/test
      mount -t nfs4 '"$LAB_APP_IP"':/share/nfs /mnt/test || { echo "FAIL: reclaim-client mount" >&2; exit 10; }
      exec 9>/mnt/test/reclaim.lock || exit 11
      flock -x 9 || exit 12
      while true; do sleep 2; echo tick >&9 2>/dev/null; done'
    lockfile="$LAB_TMPDIR/share/nfs/reclaim.lock"
    for _ in $(seq 1 30); do [ -s "$lockfile" ] && break; sleep 1; done
    [ -s "$lockfile" ] || { echo "FAIL: reclaim holder never established state"; exit 1; }
    sz0=$(stat -c %s "$lockfile")
    sleep 5 # let ticks land: the baseline must be from a flowing holder
    [ "$(stat -c %s "$lockfile")" -gt "$sz0" ] \
      || { echo "FAIL: reclaim holder ticks not reaching the server"; exit 1; }
    echo "-- restarting the app container (fresh netns, persistent /data)"
    docker restart "$LAB_NET_NAME-app" >/dev/null
    for _ in $(seq 1 60); do
      docker logs "$LAB_NET_NAME-app" 2>&1 | grep -q "legacy-services successfully started" && break
      sleep 1
    done
    sz=0
    for _ in $(seq 1 75); do # ~150 s: generous vs the ~lease/3 recovery cycle
      sz=$(stat -c %s "$lockfile" 2>/dev/null || echo 0)
      [ "$sz" -gt "$sz0" ] && break
      sleep 2
    done
    [ "$sz" -gt "$sz0" ] || { echo "FAIL: held state not reclaimed within 150s of the restart"; exit 1; }
    # The flock itself must survive: a fresh open in the same container is
    # a separate open-file-description, i.e. a valid lock contender
    if docker exec "$reclaim" flock -n /mnt/test/reclaim.lock true 2>/dev/null; then
      echo "FAIL: the held flock was lost across the restart"
      exit 1
    fi
    echo "reclaim OK: held flock survived an app restart (recovered from the tracker's records)"
  ); then
    return 1
  fi
}
