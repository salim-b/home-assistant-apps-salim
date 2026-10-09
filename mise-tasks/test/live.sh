#!/usr/bin/env bash
# shellcheck disable=SC2029  # remote/docker commands intentionally embed client-side values
#MISE description="Deploy an app to a device and run an NFS client roundtrip against the default share"
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

echo "== live test: $app on $host ($local_slug) =="

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

# The roundtrip targets the default share (/share/nfs)
default=$(jq -c 'map(select(.path == "/share/nfs")) | .[0] // empty' <<<"$shares")
[ -n "$default" ] || {
  echo "ERROR: no share with path /share/nfs is configured; refusing the roundtrip." >&2
  echo "       Configured shares:" >&2
  jq -r '.[] | "       - \(.path) (network \(.network))"' <<<"$shares" >&2
  exit 1
}
share_path=$(jq -r '.path' <<<"$default")
share_options=$(jq -r '.options' <<<"$default")
share_network=$(jq -r '.network' <<<"$default")
# exports(5): the default is read-only — writable only with an explicit rw
case ",$share_options," in
  *,rw,*) mode="rw" ;;
  *) mode="ro" ;;
esac

# The client container runs with --network host, so its source IP is this
# machine's IP — the server denies mounts from outside the share's network.
device_ip=$(getent hosts "$host_addr" | awk '{print $1; exit}')
[ -n "$device_ip" ] || { echo "ERROR: cannot resolve device address '$host_addr'" >&2; exit 1; }
host_ip=$(ip route get "$device_ip" | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')
if ! python3 -c "
import ipaddress, sys
sys.exit(0 if ipaddress.ip_address('$host_ip') in ipaddress.ip_network('$share_network', strict=False) else 1)
" 2>/dev/null; then
  echo "ERROR: this host's IP ($host_ip) is outside the share's network option" >&2
  echo "       ($share_network) — the server would deny the mount. Run from a host" >&2
  echo "       inside the network or adjust the share's network option." >&2
  exit 1
fi

CLIENT_IMAGE="local/nfs-live-client:alpine3.24"
docker image inspect "$CLIENT_IMAGE" >/dev/null 2>&1 || {
  echo "-- building the NFS client image ($CLIENT_IMAGE)"
  printf 'FROM alpine:3.24\nRUN apk add --no-cache nfs-utils\n' | docker build -t "$CLIENT_IMAGE" - >/dev/null
}

testfile="goose-live-test-$(date +%s)"
echo "-- mounting $device_ip:$share_path ($mode share) via pseudo-root, source IP $host_ip"
set +e
docker run --rm --privileged --network host \
  -e TARGET="$device_ip:$share_path" \
  -e ROOT_TARGET="$device_ip:/" \
  -e MODE="$mode" \
  -e TESTFILE="$testfile" \
  "$CLIENT_IMAGE" sh -ec '
  mkdir -p /mnt/test /mnt/root
  timeout 30 mount -t nfs4 "$TARGET" /mnt/test || { echo "FAIL: mount of $TARGET timed out or was refused"; exit 1; }
  echo "-- share listing:"; ls -la /mnt/test
  if [ "$MODE" = rw ]; then
    echo live-test-ok > "/mnt/test/$TESTFILE" || { echo "FAIL: write rejected"; exit 1; }
    grep -q live-test-ok "/mnt/test/$TESTFILE" || { echo "FAIL: read-back mismatch"; exit 1; }
    echo "PASS: write + read roundtrip"
    rm "/mnt/test/$TESTFILE" || { echo "FAIL: cleanup delete failed"; exit 1; }
    echo "PASS: delete via NFS"
  else
    if echo x > "/mnt/test/$TESTFILE" 2>/dev/null; then
      rm -f "/mnt/test/$TESTFILE"
      echo "FAIL: read-only share accepted a write"; exit 1
    fi
    echo "PASS: read-only share rejected the write"
  fi
  umount /mnt/test || { echo "FAIL: umount of the share failed"; exit 1; }
  timeout 30 mount -t nfs4 "$ROOT_TARGET" /mnt/root || { echo "FAIL: mount of the pseudo-root timed out or was refused"; exit 1; }
  echo "-- pseudo-root listing:"; ls /mnt/root
  ls /mnt/root | grep -q share || { echo "FAIL: pseudo-root does not list the share tree"; exit 1; }
  echo "PASS: pseudo-root (fsid=0) export browsable and read-only"
  umount /mnt/root || { echo "FAIL: umount of the pseudo-root failed"; exit 1; }
'
rc=$?
set -e
[ "$rc" -eq 0 ] || { echo "ERROR: roundtrip failed (rc=$rc)" >&2; exit "$rc"; }

# Confirm the written file really landed on (and disappeared from) the device
if [ "$mode" = rw ]; then
  ssh "${SSH_OPTS[@]}" "$host" "test ! -e /share/nfs/$testfile" \
    || { echo "ERROR: test file was not cleaned up on the device (/share/nfs/$testfile)" >&2; exit 1; }
  echo "PASS: write verified on the device filesystem"
fi

# Restore the original options when --test-shares backed them up in deploy
if ssh "${SSH_OPTS[@]}" "$host" "test -f /local_apps/$app/.test-shares-original.json"; then
  echo "-- restoring original app options"
  restore_result=$(ssh "${SSH_OPTS[@]}" "$host" \
    "curl -s -H \"Authorization: Bearer \$SUPERVISOR_TOKEN\" -H 'Content-Type: application/json' \
       -X POST --data-binary @/local_apps/$app/.test-shares-original.json \
       http://supervisor/addons/$local_slug/options")
  if echo "$restore_result" | jq -e '.result == "ok"' >/dev/null 2>&1; then
    ssh "${SSH_OPTS[@]}" "$host" \
      "ha apps restart $local_slug && rm -f /local_apps/$app/.test-shares-original.json"
    echo "-- original options restored, app restarted"
  else
    echo "WARNING: restoring the original options failed: $restore_result" >&2
    echo "         The backup remains at /local_apps/$app/.test-shares-original.json" >&2
  fi
fi

echo "live test OK"
