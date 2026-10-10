#!/usr/bin/env bash
# shellcheck disable=SC2029  # remote/docker commands intentionally embed client-side values
#MISE description="Deploy an app to a device and run live checks against it (app hook provides the checks)"
# NOTE: the docs (mise.jdx.dev, "Passing parent task arguments to dependencies",
# depends = [{ task = "deploy", args = ["{{ usage.app }}", ...] }]) describe
# arg/env forwarding to dependencies — but as of mise 2026.10.6 NO released
# version implements it (table/string/env forms all silently drop the args,
# tested empirically). Forward from the run script instead; switch to the
# native depends form once mise ships it.
#USAGE arg "<app>" help="App to test (repo subfolder name)" {
#USAGE   complete run="git ls-files | grep -E '^[^/]+/config.yaml$' | cut -d/ -f1"
#USAGE }
#USAGE arg "<host>" help="SSH target of the Home Assistant OS device (bare host defaults to root), e.g. root@192.168.1.11 or just 192.168.1.11"
#USAGE flag "--replace" help="Forwarded to deploy: uninstall an existing repository-installed copy first"
#USAGE flag "--test-options" help="Apply the app's test options (.mise/tasks/test/live/<app>.yaml) to the device app for the run (backup kept, restored on exit)"
set -euo pipefail
cd "$MISE_PROJECT_ROOT"

app="${usage_app?}"
host="${usage_host?}"
# Bare host (no user@) defaults to root: HAOS device access is root-based
case "$host" in *@*) ;; *) host="root@$host" ;; esac
SSH_OPTS=(-o ConnectTimeout=10)

# Forward the shared flags to deploy (native depends arg forwarding is not
# implemented in released mise versions — see the header note)
forward=()
[ "${usage_replace:-false}" = "true" ] && forward+=(--replace)
mise run deploy "$app" "$host" "${forward[@]}"

# --------------------------------------------------------------------------
# Generic live-test harness. App-specific checks live in the per-app hook
# (.mise/tasks/test/live/<app>.sh), analogous to the lab hooks:
#   - live_prepare()      optional; runs after deploy but before the app is
#                         restarted with the test options applied (e.g. create
#                         directories the options reference)
#   - live_runtime_check() optional; runs once the app is up — the actual
#                         app-specific live checks
# Contract variables (exported): LIVE_APP, LIVE_LOCAL_SLUG, LIVE_HOST,
#   LIVE_SSH_OPTS, LIVE_DEVICE_IP, LIVE_HOST_IP, LIVE_CLIENT_IMAGE,
#   LIVE_TEST_OPTIONS_FILE, LIVE_SHARES (JSON of the device options' shares)
# --------------------------------------------------------------------------
slug=$(yq -r '.slug' "$app/config.yaml")
local_slug="local_${slug}"
host_addr="${host##*@}" # strip a user@ prefix

echo "== live test: $app on $host ($local_slug) =="

wait_started() { # wait until the app reaches a running state
  local state=""
  for _ in $(seq 1 15); do
    state=$(ssh "${SSH_OPTS[@]}" "$host" "ha apps info $local_slug --raw-json" 2>/dev/null \
      | jq -r '.data.state // empty') || true
    [ "$state" = "started" ] && return 0
    sleep 2
  done
  echo "ERROR: $local_slug is not running on $host (state: ${state:-unknown})" >&2
  return 1
}

# The client container runs with --network host, so its source IP is this
# machine's IP — servers with network ACLs deny mounts/connections from
# outside their configured networks.
device_ip=$(getent hosts "$host_addr" | awk '{print $1; exit}')
[ -n "$device_ip" ] || { echo "ERROR: cannot resolve device address '$host_addr'" >&2; exit 1; }
host_ip=$(ip route get "$device_ip" | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')

CLIENT_IMAGE="local/nfs-live-client:alpine3.24"
docker image inspect "$CLIENT_IMAGE" >/dev/null 2>&1 || {
  echo "-- building the client image ($CLIENT_IMAGE)"
  printf 'FROM alpine:3.24\nRUN apk add --no-cache nfs-utils\n' | docker build -t "$CLIENT_IMAGE" - >/dev/null
}

# shellcheck disable=SC2034  # contract variables are consumed by the app hook
LIVE_APP="$app" \
  LIVE_LOCAL_SLUG="$local_slug" \
  LIVE_HOST="$host" \
  LIVE_DEVICE_IP="$device_ip" \
  LIVE_HOST_IP="$host_ip" \
  LIVE_CLIENT_IMAGE="$CLIENT_IMAGE" \
  LIVE_TEST_OPTIONS_FILE="$MISE_PROJECT_ROOT/.mise/tasks/test/live/$app.yaml" \
  LIVE_SHARES=""
export LIVE_APP LIVE_LOCAL_SLUG LIVE_HOST LIVE_DEVICE_IP LIVE_HOST_IP \
  LIVE_CLIENT_IMAGE LIVE_TEST_OPTIONS_FILE LIVE_SHARES

# Drop a previous app's hook functions first: on a default all-apps run,
# an app without prepare/check functions must not inherit the last app's
unset -f live_prepare live_runtime_check 2>/dev/null || true
hook=".mise/tasks/test/live/$app.sh"
if [ -f "$hook" ]; then
  # shellcheck source=/dev/null
  source "$hook" # sets live_prepare/live_runtime_check (optional)
fi

# --- apply test options (--test-options) -----------------------------------
if [ "${usage_test_options:-false}" = "true" ]; then
  [ -f "$LIVE_TEST_OPTIONS_FILE" ] || { echo "ERROR: no test options file '$LIVE_TEST_OPTIONS_FILE'" >&2; exit 1; }
  echo "-- applying test options ($LIVE_TEST_OPTIONS_FILE) to the app options"

  current=$(ssh "${SSH_OPTS[@]}" "$host" "ha apps info $local_slug --raw-json" 2>/dev/null \
    | jq -c '.data.options // empty')
  [ -n "$current" ] || { echo "ERROR: could not read the app's current options on $host" >&2; exit 1; }

  # Back up the original options next to the app folder for the restore step;
  # the next deploy wipes it together with the app folder. Keep a pre-existing
  # backup intact: re-running --test-options must not turn the (already
  # active) test options into the "original".
  backup="/local_apps/$app/.test-options-original.json"
  if ! ssh "${SSH_OPTS[@]}" "$host" "test -f '$backup'"; then
    printf '%s' "$current" | ssh "${SSH_OPTS[@]}" "$host" "cat > '$backup'"
  fi

  if [ "$(declare -f live_prepare)" != "" ]; then live_prepare; fi

  # POST body shape: {"options": {...}} (supervisor SCHEMA_OPTIONS wrapper);
  # the fixture's top-level keys override, missing keys are kept (deep merge:
  # objects merge, arrays — e.g. shares — are replaced)
  merged=$(jq -c -s '{options: (.[0] * .[1])}' <(printf '%s' "$current") \
    <(yq -o json '.' "$LIVE_TEST_OPTIONS_FILE"))
  result=$(printf '%s' "$merged" | ssh "${SSH_OPTS[@]}" "$host" \
    "curl -s -H \"Authorization: Bearer \$SUPERVISOR_TOKEN\" -H 'Content-Type: application/json' \
       -X POST --data-binary @- http://supervisor/addons/$local_slug/options")
  if ! echo "$result" | jq -e '.result == "ok"' >/dev/null 2>&1; then
    echo "ERROR: the supervisor rejected the test options: $result" >&2
    exit 1
  fi

  ssh "${SSH_OPTS[@]}" "$host" "ha apps restart $local_slug"
  echo "-- test options active; original options saved on the device at $backup"
  echo "   (restored automatically when this task exits)"
fi

# Runs on every exit path (trap): leaving the test options active on the
# device would be the worst possible failure mode of a test tool. Defined
# and trapped BEFORE the runtime checks — a failing check aborts under
# `set -e`, and a trap installed later would never fire (device-verified:
# the first device run left the test options active because of this).
restore_options() {
  [ "${usage_test_options:-false}" = "true" ] || return 0
  if ssh "${SSH_OPTS[@]}" "$host" "test -f '$backup'" 2>/dev/null; then
    echo "-- restoring original app options"
    if restore_result=$(ssh "${SSH_OPTS[@]}" "$host" \
      "jq -c '{options: .}' '$backup' | \
         curl -s -H \"Authorization: Bearer \$SUPERVISOR_TOKEN\" -H 'Content-Type: application/json' \
         -X POST --data-binary @- http://supervisor/addons/$local_slug/options") \
      && echo "$restore_result" | jq -e '.result == "ok"' >/dev/null 2>&1; then
      # Refuse to delete the backup if it turns out to contain the test
      # options (a previous failed run may have saved them as the "original")
      if [ -f "$LIVE_TEST_OPTIONS_FILE" ] \
        && [ "$(ssh "${SSH_OPTS[@]}" "$host" "jq -c '.shares // []' '$backup'")" \
          = "$(yq -o json '.shares // []' "$LIVE_TEST_OPTIONS_FILE" | jq -c .)" ]; then
        echo "WARNING: the device backup contains the TEST options — not applying them as" >&2
        echo "         'original'. Restore your real options via the app options UI; the" >&2
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
  else
    echo "-- note: no options backup on the device; the test options remain active —"
    echo "        restore your options via the app options UI"
  fi
}
trap restore_options EXIT

wait_started

# The runtime checks test the app's ACTUAL share configuration (device
# options), not the repo defaults: the user may have edited the shares in the
# HA UI.
LIVE_SHARES=$(ssh "${SSH_OPTS[@]}" "$host" "ha apps info $local_slug --raw-json" 2>/dev/null \
  | jq -c '.data.options.shares // []') || LIVE_SHARES="[]"
export LIVE_SHARES
if [ "$(jq length <<<"$LIVE_SHARES")" -gt 0 ] && [ "$(declare -f live_runtime_check)" != "" ]; then
  live_runtime_check
fi

echo "live test OK"
