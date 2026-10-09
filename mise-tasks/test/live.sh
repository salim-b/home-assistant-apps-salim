#!/usr/bin/env bash
# shellcheck disable=SC2029  # remote/docker commands intentionally embed client-side values
#MISE description="Deploy an app to a device and run an NFS client roundtrip against its shares"
# NOTE: the docs (mise.jdx.dev, "Passing parent task arguments to dependencies",
# depends = [{ task = "deploy", args = ["{{ usage.app }}", ...] }]) describe
# arg/env forwarding to dependencies — but as of mise 2026.10.6 NO released
# version implements it (table/string/env forms all silently drop the args,
# tested empirically). Forward from the run script instead; switch to the
# native depends form once mise ships it.
#USAGE arg "<app>" help="App to test (repo subfolder name)" {
#USAGE   complete run="git ls-files | grep -E '^[^/]+/config.yaml$' | cut -d/ -f1"
#USAGE }
#USAGE arg "<host>" help="SSH target of the Home Assistant OS device, e.g. root@192.168.1.11"
#USAGE flag "--replace" help="Forwarded to deploy: uninstall an existing repository-installed copy first"
#USAGE flag "--test-shares" help="Forwarded to deploy: apply the app's test shares (mise-tasks/test/shares/<app>.yaml) for the run"
set -euo pipefail
cd "$MISE_PROJECT_ROOT"

app="${usage_app?}"
host="${usage_host?}"
SSH_OPTS=(-o ConnectTimeout=10)

# Forward the shared flags to deploy (native depends arg forwarding is not
# implemented in released mise versions — see the header note)
forward=()
[ "${usage_replace:-false}" = "true" ] && forward+=(--replace)
[ "${usage_test_shares:-false}" = "true" ] && forward+=(--test-shares)
mise run deploy "$app" "$host" "${forward[@]}"

slug=$(yq -r '.slug' "$app/config.yaml")
local_slug="local_${slug}"
host_addr="${host##*@}" # strip a user@ prefix
backup="/local_apps/$app/.test-shares-original.json"
restored=0

echo "== live test: $app on $host ($local_slug) =="

# Restore the original options when --test-shares backed them up in deploy —
# runs on every exit path (trap), because leaving the test exports active on
# the device would be the worst possible failure mode of a test tool.
restore_options() {
  [ "$restored" = 0 ] || return 0
  restored=1
  if ssh "${SSH_OPTS[@]}" "$host" "test -f '$backup'" 2>/dev/null; then
    echo "-- restoring original app options"
    if restore_result=$(ssh "${SSH_OPTS[@]}" "$host" \
      "jq -c '{options: .}' '$backup' | \
         curl -s -H \"Authorization: Bearer \$SUPERVISOR_TOKEN\" -H 'Content-Type: application/json' \
         -X POST --data-binary @- http://supervisor/addons/$local_slug/options") \
      && echo "$restore_result" | jq -e '.result == "ok"' >/dev/null 2>&1; then
      # Refuse to delete the backup if it turns out to contain the test
      # shares (a previous failed run may have saved them as the "original")
      test_shares_json=$(yq -o json '.shares' "mise-tasks/test/shares/$app.yaml" 2>/dev/null || echo '[]')
      backup_shares=$(ssh "${SSH_OPTS[@]}" "$host" "jq -c '.shares' '$backup'")
      if [ "$backup_shares" = "$(jq -c . <<<"$test_shares_json")" ]; then
        echo "WARNING: the device backup contains the TEST shares — not applying them as" >&2
        echo "         'original'. Restore your real shares via the app options UI; the" >&2
        echo "         backup stays at $backup for reference." >&2
      else
        ssh "${SSH_OPTS[@]}" "$host" \
          "ha apps restart $local_slug && rm -f '$backup'"
        echo "-- original options restored, app restarted"
      fi
    else
      echo "WARNING: restoring the original options failed: ${restore_result:-<no response>}" >&2
      echo "         The backup remains at $backup" >&2
    fi
  elif [ "${usage_test_shares:-false}" = "true" ]; then
    echo "-- note: no options backup on the device; the test shares remain active —"
    echo "        restore your shares via the app options UI"
  fi
}
trap restore_options EXIT

# Wait for the app to reach a running state (deploy ensures it, but be
# defensive: NFS needs the server up before any mount)
state=""
for _ in $(seq 1 15); do
  state=$(ssh "${SSH_OPTS[@]}" "$host" "ha apps info $local_slug --raw-json" 2>/dev/null \
    | jq -r '.data.state // empty') || true
  [ "$state" = "started" ] && break
  sleep 2
done
[ "$state" = "started" ] || { echo "ERROR: $local_slug is not running on $host (state: ${state:-unknown})" >&2; exit 1; }

# Test against the app's ACTUAL share configuration (device options), not the
# repo defaults: the user may have edited the shares in the HA UI.
shares=$(ssh "${SSH_OPTS[@]}" "$host" "ha apps info $local_slug --raw-json" 2>/dev/null \
  | jq -c '.data.options.shares // []')
[ "$(jq length <<<"$shares")" -gt 0 ] || { echo "ERROR: no shares configured on the device app" >&2; exit 1; }

# The roundtrip is anchored on the default share (/share/nfs)
default=$(jq -c 'map(select(.path == "/share/nfs")) | .[0] // empty' <<<"$shares")
[ -n "$default" ] || {
  echo "ERROR: no share with path /share/nfs is configured; refusing the roundtrip." >&2
  echo "       Configured shares:" >&2
  jq -r '.[] | "       - \(.path) (network \(.network))"' <<<"$shares" >&2
  exit 1
}

# The client container runs with --network host, so its source IP is this
# machine's IP — the server denies mounts from outside a share's network.
device_ip=$(getent hosts "$host_addr" | awk '{print $1; exit}')
[ -n "$device_ip" ] || { echo "ERROR: cannot resolve device address '$host_addr'" >&2; exit 1; }
host_ip=$(ip route get "$device_ip" | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')

host_ip_in() { # host_ip_in <network> -> rc 0 if this host's IP is inside the network
  python3 -c "
import ipaddress, sys
sys.exit(0 if ipaddress.ip_address('$host_ip') in ipaddress.ip_network('$1', strict=False) else 1)
" 2>/dev/null
}

CLIENT_IMAGE="local/nfs-live-client:alpine3.24"
docker image inspect "$CLIENT_IMAGE" >/dev/null 2>&1 || {
  echo "-- building the NFS client image ($CLIENT_IMAGE)"
  printf 'FROM alpine:3.24\nRUN apk add --no-cache nfs-utils\n' | docker build -t "$CLIENT_IMAGE" - >/dev/null
}

# Roundtrip against one share: mount, listing, write + read-back + delete (rw;
# grace-aware retries) or EROFS assertion (ro; the write is attempted after
# the grace period has surely passed — its error message cannot be captured
# through the shell redirect, so rc-only judgement after a settled state)
test_share() { # test_share <path> <mode>
  local target="$device_ip:$1" mode="$2" testfile rc
  testfile="goose-live-test-$(date +%s)"
  echo "-- mounting $target ($mode share), source IP $host_ip"
  set +e
  docker run --rm --privileged --network host \
    -e TARGET="$target" -e MODE="$mode" -e TESTFILE="$testfile" \
    "$CLIENT_IMAGE" sh -ec '
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
    if ssh "${SSH_OPTS[@]}" "$host" "test -d '$1'" 2>/dev/null; then
      ssh "${SSH_OPTS[@]}" "$host" "test ! -e '$1/$testfile'" \
        || { echo "   ERROR: test file was not cleaned up on the device ($1/$testfile)" >&2; return 1; }
      echo "   PASS: write verified on the device filesystem"
    else
      echo "   (note: $1 not visible from the SSH session — verified via NFS read-back only)"
    fi
  fi
  return 0
}

fails=0
# mapfile: the loop body (docker/ssh) must not consume a streaming stdin
mapfile -t share_rows < <(jq -r '.[] | [.path, .network, .options] | @tsv' <<<"$shares")
for row in "${share_rows[@]}"; do
  IFS=$'\t' read -r spath snetwork soptions <<<"$row"
  [ -n "$spath" ] || continue
  case ",$soptions," in
    *,rw,*) smode="rw" ;;
    *) smode="ro" ;;
  esac
  if host_ip_in "$snetwork"; then
    test_share "$spath" "$smode" || fails=$((fails + 1))
  else
    echo "-- skipping $spath: this host's IP ($host_ip) is outside its network option ($snetwork)"
  fi
done

# Pseudo-root (fsid=0) export: browsable and read-only
echo "-- mounting $device_ip:/ (pseudo-root)"
set +e
docker run --rm --privileged --network host \
  -e ROOT_TARGET="$device_ip:/" \
  "$CLIENT_IMAGE" sh -ec '
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

# The EXIT trap restores the original options
[ "$fails" -eq 0 ] || { echo "ERROR: $fails roundtrip(s) failed" >&2; exit 1; }
echo "live test OK"
