#!/usr/bin/env bash
# shellcheck shell=bash
#MISE hide=true
#MISE description="⚠️ internal helper (sourced by device tasks, not runnable on its own)"
# SSH + supervisor-readiness helpers shared by the device tasks (deploy,
# deploy-registry). Sourced into the caller's shell: the functions use the
# caller's SSH_OPTS array (set it before sourcing) and the caller's `host`
# variable, and expect `set -euo pipefail` semantics.
# shellcheck disable=SC2154  # SSH_OPTS + host are the sourcing task's contract variables

# The supervisor may still be settling after a device reboot (the ha CLI then
# fails with e.g. "System is not ready with state: shutdown" or "Supervisor is
# not ready to perform this operation"): wait for readiness up front, and
# retry the mutating operations below on those transient messages.
wait_supervisor() { # poll until the supervisor API answers
  local n=1 probe rc
  while true; do
    # '|| rc=$?' keeps this out of errexit (set -e) so the failure can be
    # inspected instead of killing the script from inside the assignment
    probe=$(ssh "${SSH_OPTS[@]}" "$host" \
      "ha supervisor info --raw-json 2>&1 | jq -e '.result == \"ok\"' >/dev/null" 2>&1) && rc=0 || rc=$?
    [ "$rc" -eq 0 ] && return 0
    if [ "$rc" -eq 255 ]; then
      # rc=255 = ssh itself failed (network/auth) — no retry can fix that
      echo "ERROR: cannot ssh to $host: ${probe:-<no output>}" >&2
      return 1
    fi
    [ "$n" -lt 30 ] || {
      echo "ERROR: supervisor on $host not ready after 3 min (last probe: ${probe:-<no output>})" >&2
      return 1
    }
    echo "-- waiting for the supervisor to become ready ($n/30)"
    n=$((n + 1))
    sleep 6
  done
}

ha_retry() { # ha_retry <timeout-s> <cmd...>: retry commands failing with known transient messages
  local deadline=$((SECONDS + $1))
  shift
  local out rc
  while true; do
    out=$("$@" 2>&1) && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then printf '%s\n' "$out"; return 0; fi
    if ! grep -qiE "not ready|is starting|is shutdown|connection refused" <<<"$out"; then
      printf '%s\n' "$out" >&2
      return "$rc"
    fi
    [ "$SECONDS" -lt "$deadline" ] || { printf '%s\n' "$out" >&2; return "$rc"; }
    echo "-- transient supervisor failure, retrying: $(head -c 120 <<<"$out")"
    sleep 5
  done
}
