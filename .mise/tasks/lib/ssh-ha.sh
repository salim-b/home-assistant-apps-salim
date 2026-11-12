#!/usr/bin/env bash
# shellcheck shell=bash
#MISE hide=true
#MISE description="⚠️ internal helper (sourced by device tasks, not runnable on its own)"
# Sourced by the device tasks (see .agents/skills/ha-app-device-testing): call `ha_connect <host-arg>` right after
# sourcing - it sets the contract variables `host` + SSH_OPTS that the other helpers read.
# shellcheck disable=SC2154  # host + SSH_OPTS are set by ha_connect
# shellcheck disable=SC2029  # the remote commands intentionally embed client-side values (function args)

ha_connect() { # ha_connect <host>: set the contract variables - normalize the SSH target (bare host -> root@: HAOS device
  # access is root-based) and SSH_OPTS
  host="$1"
  case "$host" in *@*) ;; *) host="root@$host" ;; esac
  SSH_OPTS=(-o ConnectTimeout=10)
}

ha_app_slug() { # ha_app_slug <app>: the app's slug from its repo config.yaml (fails when the repo has no such app directory)
  [ -d "$1" ] || {
    echo "ERROR: no app directory '$1' in the repo" >&2
    return 1
  }
  yq -r '.slug' "$1/config.yaml"
}

# The supervisor may still be settling after a device reboot (transient "not ready" /
# "is shutdown" messages from the ha CLI): wait up front, retry the mutators below on those.
wait_supervisor() { # poll until the supervisor API answers
  local n=1 probe rc
  while true; do
    # '|| rc=$?' keeps the probe out of errexit so the failure stays inspectable
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
    if [ "$rc" -eq 0 ]; then
      printf '%s\n' "$out"
      return 0
    fi
    if ! grep -qiE "not ready|is starting|is shutdown|connection refused" <<<"$out"; then
      printf '%s\n' "$out" >&2
      return "$rc"
    fi
    [ "$SECONDS" -lt "$deadline" ] || {
      printf '%s\n' "$out" >&2
      return "$rc"
    }
    echo "-- transient supervisor failure, retrying: $(head -c 120 <<<"$out")"
    sleep 5
  done
}

# 'ha apps start' cannot start slow apps: the CLI caps every API call with a hard-coded 30 s HTTP client timeout and
# offers no override (full timeout catalog: root KNOWLEDGE.md §"Supervisor: ha CLI HTTP client timeouts"). The
# supervisor holds the POST's response until the app reaches the started state, so POST it directly with a curl
# timeout we control (same pattern as ha_post_options below).
APP_START_TIMEOUT=300
ha_app_start() { # ha_app_start <slug>: start the app, tolerating slow startups (hd-idle's drive spin-up)
  local result rc
  result=$(ssh "${SSH_OPTS[@]}" "$host" \
    "curl -s --max-time ${APP_START_TIMEOUT} -H \"Authorization: Bearer \$SUPERVISOR_TOKEN\" \
      -X POST http://supervisor/addons/$1/start") && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ERROR: starting $1 failed or timed out after ${APP_START_TIMEOUT}s (curl rc=$rc) - the app may" >&2
    echo "       still be starting; check: ssh $host 'ha apps logs $1'" >&2
    return 1
  fi
  if ! echo "$result" | jq -e '.result == "ok"' >/dev/null 2>&1; then
    printf 'ERROR: the supervisor rejected starting %s: %s\n' "$1" "$result" >&2
    return 1
  fi
}

ha_ensure_running() { # ha_ensure_running <slug>: ensure the app runs after an install/update/restart ('ha apps install'
  # never auto-starts; updates/rebuilds only restart when it was running): start it when the state check finds it not
  # running, then verify again. Progress on stderr, final state on stdout (capture-safe); fails with a log hint when
  # the app still won't run.
  local state
  sleep 3
  state=$(ha_retry 120 ssh "${SSH_OPTS[@]}" "$host" "ha apps info $1 --raw-json" | jq -r '.data.state // empty')
  case "$state" in
    started | startup) ;;
    *)
      echo "-- app is not running (state: $state) - starting it" >&2
      ha_app_start "$1"
      sleep 10
      state=$(ha_retry 120 ssh "${SSH_OPTS[@]}" "$host" "ha apps info $1 --raw-json" | jq -r '.data.state // empty')
      case "$state" in
        started | startup) ;;
        *)
          echo "WARNING: the app state is '$state' even after a start attempt - check the app log:" >&2
          echo "         ssh $host 'ha apps logs $1'" >&2
          return 1
          ;;
      esac
      ;;
  esac
  printf '%s\n' "$state"
}

# --- supervisor REST probes -------------------------------------------------------------------

sup_get() { # sup_get <api-path>: supervisor REST GET (read-only), raw JSON
  ssh "${SSH_OPTS[@]}" "$host" \
    "curl -s -H \"Authorization: Bearer \$SUPERVISOR_TOKEN\" http://supervisor/$1"
}

sup_expect_ok() { # sup_expect_ok <api-path> <what>: sup_get + require result=="ok" - prints the raw JSON on success,
  # fails (with the response echoed) otherwise; readiness is established (wait_supervisor), so no retries
  local out
  out=$(sup_get "$1") || out=""
  if ! echo "$out" | jq -e '.result == "ok"' >/dev/null 2>&1; then
    echo "ERROR: could not read $2 on $host: ${out:-<no output>}" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# The device resolves through the CoreDNS forward chain: manual servers, then the host's DHCP-learned DNS
# servers ("locals"), then the DoT fallback (root KNOWLEDGE.md §"Supervisor: DNS resolution chain (CoreDNS)").
# When the device's own IP is among them, whatever app serves :53 on the device sits in the device's own
# resolution path - a deploy task uninstalling that app (e.g. a hickory-dns copy) cuts the supervisor's DNS
# off, and the task's remaining DNS-dependent steps (registry downloads, store reloads, on-device builds)
# fail with a broken resolver on top.
device_resolves_through_self() { # 0 = the device's DNS servers include its own IP, 1 = no, 2 = undetermined
  local dns_info net_info own_ips resolvers
  dns_info=$(sup_get dns/info) || return 2
  net_info=$(sup_get network/info) || return 2
  # The device's own IPs: v1 nests the CIDR lists under .ipv4/.ipv6, v2 under .state/.config (both shapes
  # exist - root KNOWLEDGE.md §"Supervisor: DNS resolution chain (CoreDNS)").
  own_ips=$(jq -r '(.data.interfaces // [])[]
      | (.ipv4.address // []) + (.ipv6.address // [])
        + (.state.ipv4.addresses // []) + (.state.ipv6.addresses // [])
        + (.config.ipv4.addresses // []) + (.config.ipv6.addresses // [])
      | .[] | sub("/[0-9]+$"; "")' <<<"$net_info" 2>/dev/null) || return 2
  resolvers=$(jq -r '((.data.servers // []) + (.data.locals // []))[]
      | sub("^dns://"; "") | sub(":[0-9]+$"; "")' <<<"$dns_info" 2>/dev/null | sort -u) || return 2
  [ "$own_ips" != "" ] && [ "$resolvers" != "" ] || return 2
  local overlap
  overlap=$(comm -12 <(printf '%s\n' "$own_ips" | sort -u) <(printf '%s\n' "$resolvers"))
  [ "$overlap" != "" ]
}

# --- app options helpers (read-only probes skip ha_retry: readiness established, 'not installed' expected) ---

ha_app_options() { # ha_app_options <slug>: the install's current options as compact JSON ('' when none/unreadable)
  ssh "${SSH_OPTS[@]}" "$host" "ha apps info $1 --raw-json" 2>/dev/null \
    | jq -c '.data.options // empty' 2>/dev/null || true
}

ha_post_options() { # ha_post_options <slug> <options-json>: POST {options: ...}; fails on supervisor rejection
  local result
  result=$(printf '{"options": %s}' "$2" | ssh "${SSH_OPTS[@]}" "$host" \
    "curl -s -H \"Authorization: Bearer \$SUPERVISOR_TOKEN\" -H 'Content-Type: application/json' \
      -X POST --data-binary @- http://supervisor/addons/$1/options")
  if ! echo "$result" | jq -e '.result == "ok"' >/dev/null 2>&1; then
    printf 'supervisor rejected the options: %s\n' "$result" >&2
    return 1
  fi
}

ha_schema_keys() { # ha_schema_keys <slug>: the app's schema keys as a JSON array (the info endpoint's schema field is
  # an array of {name, ...} objects or a key->spec object - both shapes exist, device-verified 2026-10-16)
  ssh "${SSH_OPTS[@]}" "$host" "ha apps info $1 --raw-json" \
    | jq -c 'if (.data.schema | type) == "array" then [.data.schema[] | .name] else [.data.schema | keys[]] end'
}

ha_filter_options() { # ha_filter_options <options-json> <target-slug>: the options filtered to the target's schema
  # keys. A fresh options POST silently DROPS keys unknown to the schema (device-verified 2026-10-16) - the
  # filter makes those drops explicit (fact: root KNOWLEDGE.md §Supervisor: option schema quirks).
  local keys
  keys=$(ha_schema_keys "$2")
  jq -c --argjson keys "$keys" 'with_entries(select(.key as $k | $keys | index($k)))' <<<"$1"
}

ha_dropped_keys() { # ha_dropped_keys <options-json> <target-slug>: the options' keys unknown to the target's schema,
  # comma-joined ('' when none) - the counterpart of ha_filter_options, reporting the drops instead of filtering
  jq -r --argjson keys "$(ha_schema_keys "$2")" \
    'to_entries | map(select(.key as $k | $keys | index($k) | not) | .key) | join(", ")' <<<"$1"
}

ha_backup_options() { # ha_backup_options <app-name> <options-json>: back the options up to a local file (they die
  # with any destructive operation); prints the backup path
  local f
  f=$(mktemp "${TMPDIR:-/tmp}/ha-options-backup-${1}.XXXXXX.json")
  printf '%s' "$2" >"$f"
  printf '%s' "$f"
}
