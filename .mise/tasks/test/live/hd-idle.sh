#!/usr/bin/env bash
# shellcheck disable=SC2029  # remote/docker commands intentionally embed client-side values
#MISE hide=true
#MISE description="⚠️ internal helper script"
# App-specific live-test hook for hd-idle, sourced by the generic
# .mise/tasks/test/live.sh harness (same split as the lab hooks). Log-based
# checks only: HAOS ships no docker CLI, so no container-internal probes are
# possible from here. Real spindown assertions belong here once drives are
# attached to the device (see hd-idle/TODO.md).

# shellcheck disable=SC2034  # LIVE_* are the harness contract variables

live_runtime_check() {
  local logs
  logs=$(ssh "${LIVE_SSH_OPTS[@]}" -o ConnectTimeout=10 "$LIVE_HOST" \
    "ha apps logs $LIVE_LOCAL_SLUG" 2>/dev/null) || true

  if ! grep -q "symlinkPolicy=" <<<"$logs"; then
    echo "   FAIL: hd-idle config dump missing from the app log (daemon never started?)" >&2
    return 1
  fi
  echo "   PASS: hd-idle daemon started (config dump present)"

  if ! grep -q "hd-idle configuration completed" <<<"$logs"; then
    echo "   FAIL: config.sh did not complete (invalid configuration?)" >&2
    return 1
  fi
  echo "   PASS: hd-idle configuration completed"

  # Surface the system-disk exclusion and drive mapping for the operator
  grep -E "Excluding the system disk|Drive .* -> |No drives configured" \
    <<<"$logs" | tail -5 | sed 's/^/         /'
  return 0
}