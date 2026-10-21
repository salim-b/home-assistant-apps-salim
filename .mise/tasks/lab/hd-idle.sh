#!/usr/bin/env bash
#MISE hide=true
#MISE description="⚠️ internal helper script"
# App hook for .mise/tasks/lab.sh (hd-idle specifics).
#
# Contract: this file may set lab_docker_args (the app requires no volumes
# beyond the harness-provided /dev/disk mirror and /data, and the harness
# already runs the app container --privileged) and may define
# lab_runtime_check.
#
# HAOS binds the host's /dev read-only into every app container
# (supervisor/docker/const.py MOUNT_DEV, with
# read_only_non_recursive=True), so /dev/disk/by-* udev symlink trees are
# visible to the app on a real device - config.sh's system-disk detection
# and the by-id inventory rely on that. Plain Docker only creates bare
# device nodes (no /dev/disk), so mirror the HAOS behavior here (hd-idle's
# whole by-id UX would be lab-invisible otherwise).

lab_docker_args=()
if [ -d /dev/disk ]; then
  lab_docker_args+=(-v /dev/disk:/dev/disk:ro)
fi
## Short watcher interval (the 5 s floor) so the watcher roundtrips in
## lab_runtime_check complete within their poll windows (mirrors the
## nfs-server lab's NFSD_WATCH_INTERVAL).
lab_docker_args+=(-e HD_IDLE_WATCH_INTERVAL=5)
#
# The lab container sees this machine's real /dev and /proc/diskstats. The
# optional spindown smoke test is driven by LAB_SPINDOWN_DRIVES (comma-
# separated sd* kernel names, e.g. "sda,sdb" — set via
# `mise run lab hd-idle --spindown-drives sda,sdb`). It performs READ-ONLY
# standby commands + state queries (smartctl -n standby) only. The fixture
# adapter (.mise/tasks/lab/hd-idle.py) configures these drives on a
# 30 s idle so the daemon also exercises its natural spindown path within
# the check window.
#
# Host-side interference: OS-level spindown mechanisms (udisks2 stored drive
# settings, hdparm.conf, TLP, smartd, ...) and desktop IO on mounted drives
# can skew spindown tests — a read-only preflight sweep warns about them
# (background in hd-idle/KNOWLEDGE.md). Assertions are therefore event-based
# (hd-idle's own log lines, drive state right after the forced command),
# never "stays spundown for N minutes".

# shellcheck disable=SC2034  # contract variables are consumed by the harness

lab_preflight() {
  ## Read-only warning sweep for host-side disk power-management mechanisms
  ## that could interfere with spindown tests.
  local found=0 unit
  for unit in udisks2 tlp laptop-mode smartd smartmontools powertop hd-idle; do
    if systemctl is-active "$unit" >/dev/null 2>&1; then
      echo "   WARNING: host service '$unit' is active - it may spin drives down or up and skew test results" >&2
      found=1
    fi
  done
  if compgen -G '/var/lib/udisks2/*' >/dev/null 2>&1; then
    echo "   WARNING: /var/lib/udisks2 contains stored drive settings (udisksd re-applies them on every hotplug)" >&2
    found=1
  fi
  if [ -f /etc/hdparm.conf ] && grep -q . <<<"$(grep -vE '^\s*(#|$)' /etc/hdparm.conf)"; then
    echo "   WARNING: /etc/hdparm.conf carries non-comment directives" >&2
    found=1
  fi
  if [ -f /etc/tlp.conf ] && grep -q . <<<"$(grep -E '^\s*DISK_' /etc/tlp.conf)"; then
    echo "   WARNING: /etc/tlp.conf carries DISK_* settings" >&2
    found=1
  fi
  [ "$found" = 0 ] || true
  [ "$found" = 1 ] || echo "   (no host-side spindown mechanisms detected)"
}

lab_runtime_check() {
  local app="$LAB_NET_NAME-app" drives="$LAB_SPINDOWN_DRIVES" dev check_img
  IFS=' ' read -r -a drive_devs <<<"${drives//,/ }"
  local fail=0 waited=0 missing=""

  ## Boot sanity: hd-idle must be running, its config dump must be in the
  ## app log, and /proc/diskstats must be visible (kernel-global, so it shows
  ## the host's disks).
  docker exec "$app" sh -c "ps | grep -q '[h]d-idle'" \
    || {
      echo "hd-idle process not running"
      return 1
    }
  docker exec "$app" sh -c "test -r /proc/diskstats" \
    || {
      echo "/proc/diskstats not readable inside the app container"
      return 1
    }
  docker logs "$app" 2>&1 | grep -q "symlinkPolicy=" \
    || {
      echo "hd-idle config dump missing from the app log (daemon never started?)"
      return 1
    }
  docker logs "$app" 2>&1 | grep -q "Detected sd\* disks" \
    || {
      echo "config.sh disk inventory missing from the app log"
      return 1
    }
  if docker logs "$app" 2>&1 | grep -q "./run: line"; then
    echo "a run script crashed during boot (raw './run: line N:' error in the app log)"
    return 1
  fi
  docker logs "$app" 2>&1 | grep -qE "hd-idle command line: /usr/sbin/hd-idle -s 1 -c [a-z]+ -p [0-9]+ -i 0([^0-9]|$)" \
    || {
      echo "the hd-idle command line does not pin the global idle to 0 (unlisted drives would be managed)"
      return 1
    }
  echo "hd-idle up (process, /proc/diskstats, config dump, drive inventory OK)"

  lab_preflight

  ## Watcher mechanics (drive re-resolution) - run for EVERY lab, before the
  ## LAB_SPINDOWN_DRIVES gate: the roundtrips below need no spindownable
  ## drives. The watcher must detect configuration drift by replaying the
  ## recorded resolution baseline (hd-idle-genargs --check) and regenerate +
  ## restart hd-idle when it changed. A kernel-name move cannot be simulated
  ## in the lab (renames happen kernel-side), so verify the mechanism
  ## deterministically: first the hermetic --check exit-code matrix below
  ## (every detection path against a known mutation), then the roundtrips -
  ## corrupt /etc/hd-idle.args (content drift) and the baseline state file
  ## (state drift) and expect the watcher to restore within a poll interval -
  ## restarting hd-idle for the content roundtrip, while the state roundtrip
  ## must be resynced WITHOUT a restart (asserted via the watcher's
  ## change-tick log line, which only the restart path emits).
  if docker exec "$app" sh -c "test -x /usr/bin/hd-idle-genargs" 2>/dev/null; then
    ## Hermetic --check exit-code matrix: every detection path of the
    ## baseline replay, each run against a mutation with a known expected
    ## exit code (0 = unchanged, 3 = regeneration due). The watcher is
    ## paused for the matrix so no tick can race the mutations (its exit is
    ## confirmed via s6-svstat before the first mutation).
    echo "-- verifying the hd-idle-genargs --check exit-code matrix (watcher paused)"
    docker exec "$app" /command/s6-svc -d /run/service/hd-idle-watch
    mx_down=0
    for _ in {1..10}; do
      docker exec "$app" /command/s6-svstat /run/service/hd-idle-watch 2>/dev/null | grep -q '^down' \
        && mx_down=1 && break
      sleep 1
    done
    [ "$mx_down" = 1 ] \
      || {
        echo "   FAIL: the watcher did not stop for the --check matrix (s6-svc -d ignored?)"
        return 1
      }
    sleep 2 ## margin for an in-flight tick finishing after the stop signal
    docker exec "$app" sh -c '
      cp /etc/hd-idle.args /tmp/mx.args &&
      cp /etc/hd-idle.drives /tmp/mx.drives &&
      cp /etc/hd-idle.resolution /tmp/mx.state' \
      || {
        echo "   FAIL: backing up the generated files for the --check matrix failed"
        return 1
      }
    ## The boot generation must have written a state file that replays as
    ## unchanged (the matrix's clean case).
    docker exec "$app" sh -c "test -s /etc/hd-idle.resolution" \
      || {
        echo "   FAIL: /etc/hd-idle.resolution baseline missing after boot"
        return 1
      }
    mx_case() { ## <label> <mutation-command (may be empty)> <expected exit>
      local label="$1" mutate="$2" expect="$3" rc=0
      if [ "$mutate" != "" ]; then
        docker exec "$app" sh -c "$mutate" || true
      fi
      docker exec "$app" /usr/bin/hd-idle-genargs --quiet --check || rc=$?
      if [ "$rc" != "$expect" ]; then
        echo "   FAIL: matrix case '${label}': exit ${rc}, expected ${expect}"
        return 1
      fi
      echo "   PASS: matrix case '${label}' -> ${rc}"
    }
    mx_case "clean baseline replay" "" 0 || return 1
    mx_case "args file content drift" "printf 'x\n' >> /etc/hd-idle.args" 3 \
      || return 1
    mx_case "args file restore" "cp /tmp/mx.args /etc/hd-idle.args" 0 || return 1
    mx_case "drives file content drift" "printf 'x\n' >> /etc/hd-idle.drives" 3 \
      || return 1
    mx_case "drives file restore" "cp /tmp/mx.drives /etc/hd-idle.drives" 0 \
      || return 1
    mx_case "state file missing" "rm -f /etc/hd-idle.resolution" 3 || return 1
    mx_case "state file restore" "cp /tmp/mx.state /etc/hd-idle.resolution" 0 \
      || return 1
    mx_case "state file garbage" "printf 'garbage\n' > /etc/hd-idle.resolution" 3 \
      || return 1
    mx_case "state file restore (2)" "cp /tmp/mx.state /etc/hd-idle.resolution" 0 \
      || return 1
    mx_case "system-disk set drift" \
      "sed -i 's/^system.*/system mx-fake-system-disk/' /etc/hd-idle.resolution" 3 \
      || return 1
    mx_case "state file restore (3)" "cp /tmp/mx.state /etc/hd-idle.resolution" 0 \
      || return 1
    if docker exec "$app" sh -c "grep -q '^dev ' /tmp/mx.state"; then
      mx_case "device outcome drift" \
        "sed -i 's/^dev \(.*\) .*/dev \1 mx-fake-outcome/' /etc/hd-idle.resolution" 3 \
        || return 1
    else
      ## No configured drives: inject a dev line with an outcome the replay
      ## cannot confirm (the device does not exist -> PASSTHRU) - a drift
      ## nonetheless, since the recorded outcome is a kernel name.
      mx_case "device outcome drift (injected)" \
        "printf 'dev /dev/mx-no-such-device sda\n' >> /etc/hd-idle.resolution" 3 \
        || return 1
    fi
    mx_case "state file restore (4)" "cp /tmp/mx.state /etc/hd-idle.resolution" 0 \
      || return 1
    docker exec "$app" sh -c 'rm -f /tmp/mx.args /tmp/mx.drives /tmp/mx.state'
    echo "-- resuming the watcher after the matrix (s6-svc -u)"
    docker exec "$app" /command/s6-svc -u /run/service/hd-idle-watch
    mx_up=0
    for _ in {1..10}; do
      docker exec "$app" /command/s6-svstat /run/service/hd-idle-watch 2>/dev/null | grep -q '^up' \
        && mx_up=1 && break
      sleep 1
    done
    [ "$mx_up" = 1 ] \
      || {
        echo "   FAIL: the watcher did not come back up after the --check matrix"
        return 1
      }
    echo "   PASS: --check exit-code matrix green, watcher resumed"

    echo "-- verifying the drive re-resolution watcher (corrupt-args roundtrip)"
    docker exec "$app" cp /etc/hd-idle.args /tmp/args.expected
    docker exec "$app" sh -c 'printf "corrupted\n" > /etc/hd-idle.args'
    if docker exec "$app" cmp -s /etc/hd-idle.args /tmp/args.expected; then
      echo "   FAIL: the args corruption did not take effect"
      return 1
    fi
    restored=0
    for _ in {1..10}; do
      sleep 5
      if docker exec "$app" cmp -s /etc/hd-idle.args /tmp/args.expected; then
        restored=1
        break
      fi
    done
    [ "$restored" = 1 ] || {
      echo "   FAIL: args file not restored within 50 s (watcher not running?)"
      return 1
    }
    ## The restore (the watcher's args mv) precedes the restart by ~1 s (drives+state mv, pmfix, s6-svc -r, then
    ## the daemon's run script logs 'Starting hd-idle' again) - a single grep right after the cmp success can land
    ## in that window and count 1 (observed twice). Poll for the restarted daemon instead.
    restarts=0
    for _ in {1..10}; do
      restarts=$(docker logs "$app" 2>&1 | grep -c "Starting hd-idle" || true)
      [ "$restarts" -ge 2 ] && break
      sleep 1
    done
    [ "$restarts" -ge 2 ] \
      || {
        echo "   FAIL: args restored but hd-idle not restarted (Starting count: $restarts)"
        return 1
      }
    if ! docker exec "$app" sh -c "ps | grep -q '[s]bin/hd-idle'"; then
      echo "   FAIL: hd-idle process gone after the watcher restart"
      return 1
    fi
    if ! docker exec "$app" /usr/bin/hd-idle-genargs --quiet --check; then
      echo "   FAIL: baseline check not clean again after the args restore"
      return 1
    fi
    echo "   PASS: watcher restored the configuration, restarted hd-idle, baseline replays clean"

    echo "-- verifying the watcher's baseline state roundtrip (state-only resync, no restart)"
    docker exec "$app" cp /etc/hd-idle.resolution /tmp/resolution.expected
    changes_before=$(docker logs "$app" 2>&1 | grep -c "Drive device paths changed" || true)
    docker exec "$app" sh -c 'printf "corrupted\n" > /etc/hd-idle.resolution'
    resynced=0
    for _ in {1..10}; do
      sleep 5
      if docker exec "$app" cmp -s /etc/hd-idle.resolution /tmp/resolution.expected; then
        resynced=1
        break
      fi
    done
    [ "$resynced" = 1 ] || {
      echo "   FAIL: baseline state not resynced within 50 s (watcher not running?)"
      return 1
    }
    changes_after=$(docker logs "$app" 2>&1 | grep -c "Drive device paths changed" || true)
    [ "$changes_after" = "$changes_before" ] \
      || {
        echo "   FAIL: state resync took the restart path (change-tick log line count ${changes_before} -> ${changes_after}; a stale baseline must resync without a restart)"
        return 1
      }
    if ! docker exec "$app" /usr/bin/hd-idle-genargs --quiet --check; then
      echo "   FAIL: baseline check not clean after the state resync"
      return 1
    fi
    echo "   PASS: watcher resynced the baseline state without restarting hd-idle"
  else
    echo "(no hd-idle-genargs: watcher check skipped - app image predates the watcher?)"
  fi

  if [ "$drives" = "" ]; then
    echo "(no LAB_SPINDOWN_DRIVES: spindown smoke test skipped)"
    return 0
  fi

  ## Drive-PM treatment plumbing (per-drive override): the drives file
  ## carries the effective per-drive flag in a 4th column (1 = treat, 0 =
  ## leave the drive's own power management alone); the fixture adapter
  ## sets disable_drive_pm=no on the FIRST drive so the override is
  ## exercised end to end (pm-flag 0 in the file, hd-idle-pmfix logs the
  ## skip at boot).
  if ! docker exec "$app" sh -c "awk 'NF > 0 && NF != 4 { exit 1 }' /etc/hd-idle.drives"; then
    echo "   FAIL: /etc/hd-idle.drives lines are not 4 columns (pm-flag column missing)"
    return 1
  fi
  pm_skip="${drives%%,*}"
  docker exec "$app" grep -qx "${pm_skip} .* 0" /etc/hd-idle.drives \
    || {
      echo "   FAIL: override drive ${pm_skip} has no pm-flag 0 in the drives file"
      return 1
    }
  docker logs "$app" 2>&1 | grep -q "drive-PM treatment disabled for this drive" \
    || {
      echo "   FAIL: no hd-idle-pmfix skip log for the per-drive override drive"
      return 1
    }
  echo "   PASS: per-drive drive-PM override (4-column drives file, override drive skipped by hd-idle-pmfix)"

  ## Spindown smoke test (read-only on the drives).
  ##
  ## hd-idle -t quirks (verified, see hd-idle/KNOWLEDGE.md):
  ## - needs the FULL /dev path - unlike the daemon path, single-shot mode
  ##   does not prepend /dev/ (bare kernel names fail with "open sda: no
  ##   such file or directory"; the usage string's "-t sda" is misleading)
  ## - uses the GLOBAL default command type (single-shot mode has no
  ##   per-device config) - config.yaml's scsi default is what USB drives
  ##   need; the fixture sets it per drive, which -t ignores
  check_img="local/hdidle-lab-check:smartctl"
  if ! docker image inspect "$check_img" >/dev/null 2>&1; then
    echo "-- building the spindown-check image ($check_img)"
    docker build -q -t "$check_img" -f - . <<'EOF'
FROM alpine:3.24
RUN apk add --no-cache smartmontools
EOF
  fi

  for dev in "${drive_devs[@]}"; do
    if [ ! -e "/sys/block/$dev" ]; then
      echo "-- (note: $dev not present on this machine - skipping it)"
      continue
    fi
    echo "-- forced spindown of $dev (hd-idle -t, no data written)"
    if ! docker exec "$app" /usr/sbin/hd-idle -t "/dev/$dev"; then
      echo "   FAIL: hd-idle -t $dev returned an error (command type? permissions?)"
      fail=1
      continue
    fi
    ## Verify the standby state with smartctl -n standby - the probe
    ## DESIGNED not to wake drives. Verified against this machine's USB
    ## bridges: hdparm -C is NOT usable here - it races the spin-down
    ## window (NOT READY / "becoming ready" sense data) and actually WAKES
    ## the bridge's drive (empirical, see hd-idle/KNOWLEDGE.md): STOP ->
    ## smartctl says SLEEP -> hdparm -C -> smartctl says active.
    ## Desktop IO on a mounted drive may wake it between the command and
    ## the probe - hence the polling retries instead of a single read.
    local tries=0 pass="" rc
    while [ "$tries" -lt 6 ]; do
      sleep 5
      rc=0
      docker run --rm --privileged "$check_img" sh -c \
        "smartctl -H -n standby /dev/$dev 2>&1 | grep -q 'Device is in STANDBY\|Device is in SLEEP'" \
        || rc=1
      if [ "$rc" = 0 ]; then
        pass=1
        break
      fi
      tries=$((tries + 1))
    done
    if [ "$pass" = 1 ]; then
      echo "   PASS: $dev reached standby/sleep"
    else
      echo "   FAIL: $dev not in standby/sleep after $tries probes (still active - drive woken by IO, or spindown did not stick)"
      fail=1
    fi
  done
  [ "$fail" = 0 ] || return 1

  ## Natural-path assertion: the daemon (fixture idle: 30 s) must log its
  ## own spindown events for the smoke-test drives. Desktop IO on mounted
  ## drives can delay this (the drive gets woken, the daemon spins it down
  ## again) - the event must appear, the drive does not need to STAY in
  ## standby.
  echo "-- waiting for the daemon's own spindown events (fixture idle: 30 s)"
  while [ "$waited" -lt 180 ]; do
    missing=""
    for dev in "${drive_devs[@]}"; do
      [ -e "/sys/block/$dev" ] || continue
      docker logs "$app" 2>&1 | grep -q "^$dev spindown$" || missing="$missing $dev"
    done
    [ "$missing" = "" ] && break
    sleep 5
    waited=$((waited + 5))
  done
  if [ "$missing" != "" ]; then
    echo "   FAIL: no spindown event logged for:$missing within 180 s (busy/mounted drive? host IO keeping it awake?)"
    return 1
  fi
  echo "   PASS: daemon logged its own spindown events for all smoke-test drives"

  return 0
}
