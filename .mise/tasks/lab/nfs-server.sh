#!/usr/bin/env bash
#MISE hide=true
#MISE description="⚠️ internal helper script"
# App hook for .mise/tasks/lab.sh (nfs-server specifics); general contract (lab_docker_args append
# semantics, lab_runtime_check, fixture adapters in .mise/tasks/lab/<app>.py):
# see .agents/skills/ha-app-lab-testing.
#
# shellcheck disable=SC2034  # contract variables are consumed by the harness

## Short watcher tick: the runtime check waits out a full poll interval per watcher phase (replug,
## unplug, quiet tick), so a 5 s tick (the watcher's floor) keeps each phase near the grace-period
## floor (~15 s). The watcher logic is interval-agnostic (nfs-server/KNOWLEDGE.md); production keeps
## the 30 s default (the env var is unset there).
lab_watch_interval=5
## Privileged mounts (nfsd filesystem, per-share bind mirrors); share/media
## stand-ins like on a real device
lab_docker_args+=(
  -v "$LAB_TMPDIR/share:/share"
  -v "$LAB_TMPDIR/media:/media"
  ## Drive content for the replug test (bound over /media/usb0 in-container by the runtime check): must
  ## be an NFS-exportable filesystem - the container's overlayfs root is NOT, and exportfs refuses
  ## overlay-backed mirrors.
  -v "$LAB_TMPDIR/drive-b:/mnt/drive-b"
  -e "NFSD_WATCH_INTERVAL=$lab_watch_interval"
)
mkdir -p "$LAB_TMPDIR/drive-b"
echo b-content >"$LAB_TMPDIR/drive-b/b.txt"

## Fixture adaptation: .mise/tasks/lab/nfs-server.py (every share's client network must point at the lab subnet)

lab_runtime_check() {
  ## `docker logs --since` keeps polls O(window) instead of O(full history) - the container's log
  ## history only grows (boot + roundtrip logs pile up), and the container shares the host's clock,
  ## so the host wall-clock anchors are valid.
  log_since() { # $1: pattern, $2: unix wall-clock ts to start counting from
    docker logs --since "$2" "$LAB_NET_NAME-app" 2>&1 | grep -c "$1" || true
  }

  ## Client-recovery tracker (cld): daemon + sqlite store on /data + the kernel's upcall pipe in the
  ## container's rpc_pipefs instance; "Using nfsdcld client tracking operations" in the kernel log is
  ## the end-to-end proof (the kernel logs it only after the daemon answered GetVersion + GraceStart).
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
    || {
      echo "kernel did not use the cld tracker; NFSD log tail: $klog"
      return 1
    }
  grep -q "no clients to reclaim, skipping NFSv4 grace period" <<<"$klog" \
    || {
      echo "expected the skip-grace path (fresh /data, no records); NFSD log tail: $klog"
      return 1
    }
  echo "recovery tracker up (nfsdcld, sqlite on /data, kernel upcalls + skip-grace OK)"

  echo "host-file" >"$LAB_TMPDIR/share/nfs/hostfile.txt" 2>/dev/null \
    || { mkdir -p "$LAB_TMPDIR/share/nfs" && echo "host-file" >"$LAB_TMPDIR/share/nfs/hostfile.txt"; }
  docker rm -f "$LAB_NET_NAME-client" >/dev/null 2>&1 || true
  roundtrip_out=""
  roundtrip_rc=0
  roundtrip_out=$(docker run --rm --privileged --name "$LAB_NET_NAME-client" --network "$LAB_NET_NAME" \
    local/nfslab-client:alpine3.24 sh -c "
    mkdir -p /mnt/test
    mount -t nfs4 -o timeo=5 '$LAB_APP_IP:/share/nfs' /mnt/test || exit 10
    grep -q 'host-file' /mnt/test/hostfile.txt || exit 11
    echo client-write > /mnt/test/client.txt || exit 12
    sync" 2>&1) || roundtrip_rc=$?
  [ "$roundtrip_rc" = 0 ] \
    || {
      echo "NFS roundtrip failed (rc=$roundtrip_rc)"
      if [ "$roundtrip_out" != "" ]; then echo "$roundtrip_out"; fi
      return 1
    }
  if ! grep -q "client-write" "$LAB_TMPDIR/share/nfs/client.txt"; then
    echo "client write did not reach the host filesystem"
    return 1
  fi
  echo "NFS roundtrip OK (rw write reached the host filesystem)"

  ## nfsd-watch mirror refresh: an in-container unplug/replug of a "drive" mounted at the /media share
  ## path (privileged: bind over the share path = replug, its umount = unplug) must be picked up within
  ## a poll interval without an app restart - the export switches to the new mount's content and, on
  ## unplug, stops serving the detached superblock clone (the stale-serving hazard the pre-watcher code
  ## had). The real trigger path (HAOS mounts under /media, propagated rslave) is supervisor-source-
  ## verified: nfs-server/KNOWLEDGE.md.
  if ! (
    set -e

    ## The watcher logs the detected change first and restarts the kernel server last - the export only
    ## switches once BOTH log lines are in, so gate the client roundtrips on those (cheap docker-logs
    ## polls) instead of spinning up a client per poll (burned a container per tick - the lab's biggest
    ## runtime cost - and leaked failing grep errors into the output). Each phase anchors its own log
    ## window and asserts its own cycle (1 change + 1 server start).

    ## Wait until the watcher logged a change and the cycle's server restart completed (both within the
    ## phase's --since window, which covers one poll interval plus the cycle's runtime).
    wait_watcher_cycle() {
      local changed=0 started=0
      local max_polls=40
      local i
      for ((i = 0; i < max_polls; i++)); do
        changed=$(log_since "Share mount state changed" "$phase_start_wall")
        [ "$changed" -ge 1 ] || {
          sleep 0.5
          continue
        }
        started=$(log_since "NFS server started (kernel threads running)" "$phase_start_wall")
        [ "$started" -ge 1 ] && return 0
        sleep 0.5
      done
      echo "FAIL: watcher did not complete the change cycle within the wait window (saw $changed changes / $started server starts)"
      return 1
    }

    ## One throwaway client per check: mount with retries against a cycling server, then poll - the
    ## kernel's grace period (lease_time, 15 s in the fixture) delays the client's state ops (NFSv4
    ## OPEN) until it ends, so the poll window covers grace + the cycle's runtime.
    ##
    ## timeo=150 here (unlike the reclaim client's tight timeo=5): a new client's OPEN is queued until
    ## grace ends, and a short RPC timeout expires mid-stall and forces NFSv4 state-recovery cycles
    ## (~4 s backoff each) on top of the grace wait. A down server still fails the mount fast (TCP
    ## connect refuses, unaffected by timeo) and hits the mount-retry loop.
    client_check() { # $1: export path, $2: test command, $3: failure label
      local out=""
      if out=$(docker run --rm --privileged --network "$LAB_NET_NAME" local/nfslab-client:alpine3.24 sh -c "
          mkdir -p /mnt/m
          for i in \$(seq 1 15); do
            if mount -t nfs4 -o timeo=150 '$LAB_APP_IP:$1' /mnt/m 2>/dev/null; then break; fi
            sleep 1
          done
          mountpoint -q /mnt/m || { echo 'mount failed after retries' >&2; exit 10; }
          for i in \$(seq 1 60); do
            if $2 2>/dev/null; then exit 0; fi
            sleep 1
          done
          exit 11" 2>&1); then
        return 0
      fi
      echo "FAIL: $3"
      if [ "$out" != "" ]; then echo "$out"; fi
      return 1
    }

    ## "Replug": fresh content as a new mount object at the same path (source = the /mnt/drive-b host bind
    ## - an NFS-exportable filesystem, unlike the container's overlay rootfs)
    ts "$SECONDS" "-- replug: waiting for the drive content to reappear under the new mountpoint"
    phase_start_wall=$(date +%s)
    replug_out=$(docker exec "$LAB_NET_NAME-app" mount --bind /mnt/drive-b /media/usb0 2>&1) \
      || {
        echo "FAIL: replug simulation (in-container bind over the share path)"
        if [ "$replug_out" != "" ]; then echo "$replug_out"; fi
        exit 1
      }
    wait_watcher_cycle
    client_check "/media/usb0" "grep -q b-content /mnt/m/b.txt" \
      "replug: export did not switch to the new mount's content within the wait window"
    echo "watcher replug OK: export switched to the new mount's content"

    ## "Unplug": remove the mount again - the mirror would keep serving the detached clone, so the export
    ## must become empty (also the umount-after-rpc.nfsd-0 assertion: the cycle's proven order releases the pins)
    ts "$SECONDS" "-- unplug: waiting for the stale (detached) mirror content to disappear"
    phase_start_wall=$(date +%s)
    unplug_out=$(docker exec "$LAB_NET_NAME-app" umount /media/usb0 2>&1) \
      || {
        echo "FAIL: unplug simulation (in-container umount of the share path)"
        if [ "$unplug_out" != "" ]; then echo "$unplug_out"; fi
        exit 1
      }
    wait_watcher_cycle
    client_check "/media/usb0" "! test -e /mnt/m/b.txt" \
      "unplug: unplugged share still serves stale (detached-superblock) content"
    echo "watcher unplug OK: stale content no longer served, kernel server cycled twice (empty export now)"

    ## The other share must be unaffected by the cycles
    client_check "/share/nfs" "grep -q host-file /mnt/m/hostfile.txt" \
      "/share/nfs roundtrip broke after the watcher cycles"
    echo "watcher cycles OK: /share/nfs unaffected"

    ## Quiet ticks: a full poll interval without mount changes must not restart the server
    ts "$SECONDS" "-- quiet-tick: one full poll interval without mount changes (server must stay up)"
    phase_start_wall=$(date +%s)
    sleep $((lab_watch_interval + 5))
    [ "$(log_since "Share mount state changed" "$phase_start_wall")" = 0 ] \
      || {
        echo "FAIL: watcher logged a mount change without one (spurious cycle)"
        exit 1
      }
    echo "watcher quiet-tick OK (no restart without a change)"
  ); then
    return 1
  fi

  ## Client-state reclaim across an app restart (the recovery tracker's actual feature): hold an
  ## exclusive flock from a dedicated client, restart the app container (fresh netns, sqlite store
  ## on /data persists) and verify the held state survives - a plain boot cannot catch broken store
  ## paths or missing record persistence (boot, boot log and roundtrip all still pass). The fixture's
  ## short lease (15 s) and the holder's tight RPC timeout (timeo=5) make recovery land seconds after
  ## the restarted server is up (a default 60 s timeout would wait out the retransmission interval).
  if ! (
    reclaim="$LAB_NET_NAME-reclaim"
    trap 'docker rm -f "$reclaim" >/dev/null 2>&1 || true' EXIT
    docker run -d --privileged --name "$reclaim" --network "$LAB_NET_NAME" \
      local/nfslab-client:alpine3.24 sleep infinity >/dev/null
    # Holder: open + exclusive flock + periodic writes through the held fd - the ticks drive the client's
    # recovery; the server-side file growth is the recovery-landed signal (client-side stat/mountstats
    # lie from the page cache)
    docker exec -d "$reclaim" sh -c '
      mkdir -p /mnt/test
      mount -t nfs4 -o timeo=5 '"$LAB_APP_IP"':/share/nfs /mnt/test || { echo "FAIL: reclaim-client mount" >&2; exit 10; }
      exec 9>/mnt/test/reclaim.lock || exit 11
      flock -x 9 || exit 12
      while true; do sleep 2; echo tick >&9 2>/dev/null; done'
    lockfile="$LAB_TMPDIR/share/nfs/reclaim.lock"
    for _ in {1..30}; do
      [ -s "$lockfile" ] && break
      sleep 1
    done
    [ -s "$lockfile" ] || {
      echo "FAIL: reclaim holder never established state"
      exit 1
    }
    sz0=$(stat -c %s "$lockfile")
    sleep 5 # let ticks land: the baseline must be from a flowing holder
    [ "$(stat -c %s "$lockfile")" -gt "$sz0" ] \
      || {
        echo "FAIL: reclaim holder ticks not reaching the server"
        exit 1
      }
    ts "$SECONDS" "-- restarting the app container (fresh netns, persistent /data)"
    restart_wall=$(date +%s)
    docker restart "$LAB_NET_NAME-app" >/dev/null
    # Count only post-restart lines (--since the restart): a whole-log grep was already true immediately
    # (it matched the first boot) and gets slower as the container's history grows.
    boot_ok=0
    for _ in {1..60}; do
      if [ "$(log_since "legacy-services successfully started" "$restart_wall")" -ge 1 ]; then
        boot_ok=1
        break
      fi
      sleep 0.5
    done
    [ "$boot_ok" = 1 ] || {
      echo "FAIL: restarted app did not reach legacy-services start within the boot window"
      exit 1
    }
    sz=0
    # Recovery lands seconds after the restarted server is up (the holder's tight write retries); 45 s covers a slow boot.
    for _ in {1..45}; do
      sz=$(stat -c %s "$lockfile" 2>/dev/null || echo 0)
      [ "$sz" -gt "$sz0" ] && break
      sleep 1
    done
    [ "$sz" -gt "$sz0" ] || {
      echo "FAIL: held state not reclaimed within 45s of the restart"
      exit 1
    }
    # The flock itself must survive: a fresh open in the same container is a separate open-file-description,
    # i.e. a valid lock contender
    if docker exec "$reclaim" flock -n /mnt/test/reclaim.lock true 2>/dev/null; then
      echo "FAIL: the held flock was lost across the restart"
      exit 1
    fi
    echo "reclaim OK: held flock survived an app restart (recovered from the tracker's records)"
  ); then
    return 1
  fi
}
