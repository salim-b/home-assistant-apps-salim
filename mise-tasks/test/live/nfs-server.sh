#!/usr/bin/env bash
# shellcheck disable=SC2029  # remote/docker commands intentionally embed client-side values
# App-specific live-test hook for nfs-server, sourced by the generic
# mise-tasks/test/live.sh harness (same split as the lab tasks). Uses the
# harness contract variables (LIVE_*); defines:
#   - live_prepare()       create the share directories the test options
#                          reference (the app validates that they exist) and
#                          hand the writable ones to the squashed uid
#   - live_runtime_check() the NFS client roundtrips: per-share mount /
#                          write+read+delete (rw) or EROFS assertion (ro) /
#                          pseudo-root browse

# shellcheck disable=SC2034  # LIVE_* are the harness contract variables

live_prepare() {
  # The test options reference share paths on the device host; create missing
  # ones and hand the writable ones to the squashed uid (default_uid 1000) so
  # the roundtrip can write into them. (-n: keep the loop's stdin away from ssh)
  while IFS=$'\t' read -r spath sopts; do
    [ -n "$spath" ] || continue
    case ",$sopts," in
      *,rw,*)
        ssh -n "${LIVE_SSH_OPTS[@]}" "$LIVE_HOST" \
          "mkdir -p '$spath' && chown 1000:1000 '$spath'"
        ;;
      *)
        ssh -n "${LIVE_SSH_OPTS[@]}" "$LIVE_HOST" "mkdir -p '$spath'"
        ;;
    esac
  done < <(yq -r '.shares[] | [.path, .options] | @tsv' "$LIVE_TEST_OPTIONS_FILE")
}

live_runtime_check() {
  local fails=0 spath snetwork soptions smode rc row

  # Mode detection per share: exports(5) defaults to read-only — writable
  # only with an explicit rw
  share_mode() {
    case ",$1," in
      *,rw,*) echo "rw" ;;
      *) echo "ro" ;;
    esac
  }

  # Roundtrip against one share: mount, listing, write + read-back + delete
  # (rw; grace-aware retries) or EROFS assertion (ro; the write is attempted
  # after the grace period has surely passed — its error message cannot be
  # captured through the shell redirect, so rc-only judgement after a settled
  # state)
  test_share() { # test_share <path> <mode>
    local target="$LIVE_DEVICE_IP:$1" mode="$2" testfile rc
    testfile="goose-live-test-$(date +%s)"
    echo "-- mounting $target ($mode share), source IP $LIVE_HOST_IP"
    set +e
    docker run --rm --privileged --network host \
      -e TARGET="$target" -e MODE="$mode" -e TESTFILE="$testfile" \
      "$LIVE_CLIENT_IMAGE" sh -ec '
    mkdir -p /mnt/test
    timeout 30 mount -t nfs4 "$TARGET" /mnt/test || { echo "FAIL: mount of $TARGET timed out or was refused"; exit 1; }
    echo "   -- share listing:"; ls -la /mnt/test

    if [ "$MODE" = rw ]; then
      # The server refuses writes during its post-restart grace period
      # (~10s); retry until writes settle (max ~30s).
      i=0
      until echo live-test-ok > "/mnt/test/$TESTFILE" 2>/dev/null; do
        i=$((i + 1))
        [ $i -lt 30 ] || { echo "FAIL: write kept failing for 30s"; exit 1; }
        sleep 1
      done
      grep -q live-test-ok "/mnt/test/$TESTFILE" || { echo "FAIL: read-back mismatch"; exit 1; }
      echo "   PASS: write + read roundtrip"
      rm "/mnt/test/$TESTFILE" || { echo "FAIL: cleanup delete failed"; exit 1; }
      echo "   PASS: delete via NFS"
    else
      sleep 12 # outlast the (max 10s) grace period so the denial is final
      if echo x > "/mnt/test/$TESTFILE" 2>/dev/null; then
        rm -f "/mnt/test/$TESTFILE" 2>/dev/null
        echo "FAIL: read-only share accepted a write"; exit 1
      fi
      echo "   PASS: read-only share rejected the write"
    fi

    umount /mnt/test || { echo "FAIL: umount of the share failed"; exit 1; }
  '
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || { echo "   ERROR: roundtrip against $1 failed (rc=$rc)" >&2; return "$rc"; }
    # Confirm the written file really landed on (and disappeared from) the
    # device filesystem (needs the path to be visible from the SSH session)
    if [ "$mode" = rw ]; then
      if ssh "${LIVE_SSH_OPTS[@]}" "$LIVE_HOST" "test -d '$1'" 2>/dev/null; then
        ssh "${LIVE_SSH_OPTS[@]}" "$LIVE_HOST" "test ! -e '$1/$testfile'" \
          || { echo "   ERROR: test file was not cleaned up on the device ($1/$testfile)" >&2; return 1; }
        echo "   PASS: write verified on the device filesystem"
      else
        echo "   (note: $1 not visible from the SSH session — verified via NFS read-back only)"
      fi
    fi
    return 0
  }

  # The roundtrip is anchored on the default share (/share/nfs): refuse the
  # run without it (only perform roundtrips if the default share exists)
  if [ "$(jq -r 'map(select(.path == "/share/nfs")) | length' <<<"$LIVE_SHARES")" -eq 0 ]; then
    echo "ERROR: no share with path /share/nfs is configured; refusing the roundtrip." >&2
    echo "       Configured shares:" >&2
    jq -r '.[] | "       - \(.path) (network \(.network))"' <<<"$LIVE_SHARES" >&2
    return 1
  fi

  # Per-share roundtrips; shares whose network does not contain this host's
  # IP cannot be mounted from here (the server denies them) — skipped with a
  # note; their export generation is still covered by the app booting with
  # them configured.
  # mapfile: the loop body (docker/ssh) must not consume a streaming stdin
  mapfile -t share_rows < <(jq -r '.[] | [.path, .network, .options] | @tsv' <<<"$LIVE_SHARES")
  for row in "${share_rows[@]}"; do
    IFS=$'\t' read -r spath snetwork soptions <<<"$row"
    [ -n "$spath" ] || continue
    smode=$(share_mode "$soptions")
    if python3 -c "
import ipaddress, sys
sys.exit(0 if ipaddress.ip_address('$LIVE_HOST_IP') in ipaddress.ip_network('$snetwork', strict=False) else 1)
" 2>/dev/null; then
      test_share "$spath" "$smode" || fails=$((fails + 1))
    else
      echo "-- skipping $spath: this host's IP ($LIVE_HOST_IP) is outside its network option ($snetwork)"
    fi
  done

  # Pseudo-root (fsid=0) export: browsable and read-only
  echo "-- mounting $LIVE_DEVICE_IP:/ (pseudo-root)"
  set +e
  docker run --rm --privileged --network host \
    -e ROOT_TARGET="$LIVE_DEVICE_IP:/" \
    "$LIVE_CLIENT_IMAGE" sh -ec '
  mkdir -p /mnt/root
  timeout 30 mount -t nfs4 "$ROOT_TARGET" /mnt/root || { echo "FAIL: mount of the pseudo-root timed out or was refused"; exit 1; }
  echo "   -- pseudo-root listing:"; ls /mnt/root
  ls /mnt/root | grep -q share || { echo "FAIL: pseudo-root does not list the share tree"; exit 1; }
  echo "   PASS: pseudo-root (fsid=0) export browsable"
  if echo x > /mnt/root/probe 2>/dev/null; then
    rm -f /mnt/root/probe
    echo "FAIL: pseudo-root accepted a write"; exit 1
  fi
  echo "   PASS: pseudo-root rejected the write (ro enforced)"
  umount /mnt/root || { echo "FAIL: umount of the pseudo-root failed"; exit 1; }
'
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fails=$((fails + 1))

  [ "$fails" -eq 0 ] || { echo "ERROR: $fails roundtrip(s) failed" >&2; return 1; }
  return 0
}
