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
# and may define
# - lab_runtime_check : function running the app's runtime roundtrip
#                       (runs after boot, before the graceful stop).
# Status lines use the harness's ts helper ([t+Xs] step timestamps).
#
# Fixture adaptation (rewriting config options for the lab network) lives
# separately in .mise/tasks/lab/<app>.py by convention (no hook variable;
# the harness serves it to the fake supervisor API when the file exists).
#
# shellcheck disable=SC2034  # contract variables are consumed by the harness

## Short watcher tick for the lab run: the runtime check waits out a full poll interval per watcher phase (replug,
## unplug, quiet tick), which at the production default (30 s) dominates the lab's runtime. 5 s is the watcher's
## floor (see the app's nfsd-watch) and keeps each phase at the grace-period floor (~15 s) plus the tick itself.
## The watcher logic is interval-agnostic (see the app's KNOWLEDGE.md); production keeps the 30 s default (the env
## var is unset there).
lab_watch_interval=5
## Privileged mounts (nfsd filesystem, per-share bind mirrors); share/media
## stand-ins like on a real device
lab_docker_args+=(
  -v "$LAB_TMPDIR/share:/share"
  -v "$LAB_TMPDIR/media:/media"
  ## Simulated drive content for the nfsd-watch replug test: bound over
  ## /media/usb0 in-container by the runtime check. Must live on a
  ## NFS-exportable filesystem (a plain docker bind of this host dir - the
  ## container's overlayfs root is NOT exportable and overlay-backed mirrors
  ## make exportfs refuse the export).
  -v "$LAB_TMPDIR/drive-b:/mnt/drive-b"
  -e "NFSD_WATCH_INTERVAL=$lab_watch_interval"
)
mkdir -p "$LAB_TMPDIR/drive-b"
echo b-content >"$LAB_TMPDIR/drive-b/b.txt"

## The fixture adaptation itself lives in .mise/tasks/lab/nfs-server.py
## (convention: every share's client network must point at the lab subnet
## for the roundtrip to be allowed)

lab_runtime_check() {
  ## Log polling helper shared by the watcher and reclaim phases: `docker logs` always streams the full container
  ## history, which gets slower as the run progresses (boot + roundtrip logs pile up). `docker logs --since <ts>`
  ## keeps every poll O(window) instead of O(full log) - the container shares the host's clock, so the host's
  ## wall-clock anchors are valid.
  log_since() { # $1: pattern, $2: unix wall-clock ts to start counting from
    docker logs --since "$2" "$LAB_NET_NAME-app" 2>&1 | grep -c "$1" || true
  }

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

  ## nfsd-watch mirror refresh: an unplug/replug of a "drive" mounted at the /media share path must be picked up by
  ## the watcher within its poll interval (+ margin) without an app restart - the export must switch to the new
  ## mount's content and, on unplug, stop serving the detached superblock clone (the stale-serving hazard the
  ## pre-watcher code had). Simulated in-container (the lab app container is privileged: a bind over the share path
  ## = replug, its umount = unplug). The real trigger path (HAOS mounts under /media, propagated rslave into the
  ## container) is supervisor-source-verified, see the app's KNOWLEDGE.md.
  if ! (
    set -e

    ## The watcher logs the detected change first and restarts the kernel server last, so the export only switches
    ## once BOTH log lines are in. Gating the client roundtrips on those log lines (cheap docker-logs polls)
    ## replaces the old spin-up-a-client-per-poll loop: it burned a container per poll until the tick landed (the
    ## lab's biggest runtime cost) and leaked the client's failing grep errors into the output. Each phase anchors
    ## its own log window (`phase_start_wall`) and asserts its own cycle (1 change + 1 server start).

    ## Wait until the watcher has logged a change and the cycle's server restart completed (both within the
    ## phase's --since window). The window covers one poll interval plus the cycle's runtime.
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

    ## Mount the export in a throwaway client and run the test command. Output is captured so only failures
    ## surface. One client per check: mount (with retries against a cycling server) then poll for the condition -
    ## the kernel's grace period (lease_time, 15 s in the fixture) delays the client's state ops (NFSv4 OPEN) until
    ## it ends, so the poll window covers grace + the cycle's own runtime.
    ##
    ## timeo=150 (15 s RPC timeout) here, unlike the reclaim client's tight timeo=5: a new client's OPEN is queued
    ## by the server until grace ends, and a short RPC timeout expires mid-stall and forces NFSv4 state-recovery
    ## cycles (~4 s of backoff each) on top of the grace wait. The long timeout rides out the stall in a single
    ## RPC; a down server still fails the mount fast (TCP connect refuses, unaffected by timeo) and hits the
    ## mount-retry loop.
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

    ## "Replug": fresh content as a new mount object at the same path (source = the /mnt/drive-b host bind - an
    ## NFS-exportable filesystem, unlike the container's overlay rootfs)
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

    ## "Unplug": remove the mount again - the mirror would keep serving the detached clone; the export must become
    ## empty (this is also the umount-after-rpc.nfsd-0 assertion: the cycle's proven order releases the pins)
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

  ## Client-state reclaim across an app restart (the recovery tracker's
  ## actual feature): hold an exclusive flock from a dedicated client,
  ## restart the app container (fresh netns, sqlite store on /data
  ## persists) and verify the held state survives. Catches the tracker
  ## regressions a plain boot cannot: a broken store path or missing record
  ## persistence fails only the ACROSS-RESTART property, while boot, boot
  ## log and roundtrip all still pass. The lease override in the fixture
  ## adapter (.mise/tasks/lab/nfs-server.py) (90 s) keeps the client's
  ## renewal/recovery cycle short, and the mount's short RPC timeout
  ## (timeo=5) keeps the holder's write retries tight, so recovery lands
  ## seconds after the restarted server is up - with the default 60 s
  ## timeout a write issued during the downtime waits out its full
  ## retransmission interval first.
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
    # Wait for the RESTARTED boot: counting only post-restart lines (docker
    # logs --since the restart) sidesteps the old instance's log entirely -
    # a whole-log grep was already true immediately (it matched the first
    # boot) and gets slower as the container's history grows.
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
    # Recovery lands seconds after the restarted server is up (the holder's
    # tight write retries); 45 s still covers a slow boot.
    for _ in {1..45}; do
      sz=$(stat -c %s "$lockfile" 2>/dev/null || echo 0)
      [ "$sz" -gt "$sz0" ] && break
      sleep 1
    done
    [ "$sz" -gt "$sz0" ] || {
      echo "FAIL: held state not reclaimed within 45s of the restart"
      exit 1
    }
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
