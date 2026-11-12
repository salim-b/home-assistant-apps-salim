#!/usr/bin/env bash
#MISE description="Apply a JSON (or YAML) options file to an installed HA app on a device - schema-filtered, previous options backed up"
#USAGE arg "<app>" help="App to apply the options to (repo subfolder name)" {
#USAGE   complete run="git ls-files | grep -E '^[^/]+/config.yaml$' | cut -d/ -f1"
#USAGE }
#USAGE arg "<host>" help="SSH target of the Home Assistant OS device (bare host defaults to `root`), e.g. `root@homeassistant.local` or just `homeassistant.local`"
#USAGE arg "<file>" help="""
#USAGE   JSON file with the options to apply (top-level option keys, e.g. `options.json`; `.yaml`/`.yml` files are converted
#USAGE   via yq; relative paths resolve from the mise invocation directory). The schema-filtered keys become the install's
#USAGE   complete options - a fresh options POST replaces the stored set (unknown keys are dropped, reported), and the
#USAGE   previous options are backed up locally first (path printed).
#USAGE """
#USAGE flag "--slug <slug>" help="Apply to this exact install slug on the device instead of auto-detecting the app's installed copy (e.g. `local_nfs-server` or `f8b2d53d_nfs-server`)"
#USAGE flag "--no-restart" help="Do not restart/start the app after posting - the options apply at its next start"
#USAGE flag "--dry-run" help="Show the schema-filtered options and dropped keys; change nothing on the device"
# shellcheck disable=SC2029  # remote commands intentionally embed client-side values

set -euo pipefail

app="${usage_app:?}"
file="${usage_file:?}"

# --- read and validate the options file --------------------------------------------------------
# Relative paths resolve from the mise invocation directory (tasks run in the project root;
# MISE_ORIGINAL_CWD holds the caller's cwd - the same directory for repo-root invocations).
if [ "${file#/}" = "$file" ] && [ -f "${MISE_ORIGINAL_CWD:-.}/$file" ]; then
  file="${MISE_ORIGINAL_CWD:-.}/$file"
fi
[ -f "$file" ] || {
  echo "ERROR: options file '$file' not found (absolute path, or relative to the mise invocation directory)" >&2
  exit 1
}
# .yaml/.yml are converted via yq like the test options; .json is parsed by jq exactly (no YAML 1.1 coercions)
check='if length == 1 and (.[0] | type == "object" and length > 0) then .[0] else empty end'
case "$file" in
  *.yaml | *.yml) options=$(yq -o json '.' "$file" 2>/dev/null | jq -cse "$check" 2>/dev/null) || options="" ;;
  *) options=$(jq -cse "$check" "$file" 2>/dev/null) || options="" ;;
esac
[ "$options" != "" ] || {
  echo "ERROR: '$file' must contain exactly one non-empty JSON object with the app's top-level option keys" >&2
  echo "       (not valid JSON, wrong type, empty, or several documents; YAML for .yaml/.yml files)" >&2
  exit 1
}

# shellcheck source=.mise/tasks/lib/ssh-ha.sh
source "$MISE_PROJECT_ROOT/.mise/tasks/lib/ssh-ha.sh"
ha_connect "${usage_host:?}"
slug=$(ha_app_slug "$app")
local_slug="local_${slug}"
wait_supervisor

echo "== applying options from $file to $app on $host =="

# --- discover the install to apply to ------------------------------------------------------------
# Stored options are per-install: the local copy uses the slug 'local_<slug>', a repository install the hashed
# store slug '<repo-hash>_<slug>' (fact: root KNOWLEDGE.md §"Supervisor: store slugs (in-app documentation links)").
store=$(sup_expect_ok store/addons "the app store listing")
if [ "${usage_slug:-}" != "" ]; then
  installed=$(echo "$store" | jq -c --arg s "$usage_slug" \
    '[.data.addons[] | select(.slug == $s and .installed == true)]')
else
  installed=$(echo "$store" | jq -c --arg local "$local_slug" --arg suffix "$slug" \
    '[.data.addons[] | select(.installed == true and (.slug == $local or ((.slug | split("_")) | last) == $suffix))]')
fi
case "$(jq 'length' <<<"$installed")" in
  1)
    target=$(jq -r '.[0].slug' <<<"$installed")
    version=$(jq -r '.[0].version' <<<"$installed")
    echo "-- target install: $target (version $version)"
    ;;
  0)
    if [ "${usage_slug:-}" != "" ]; then
      echo "ERROR: no installed app '${usage_slug}' on $host (is the slug right? it must name an installed copy)" >&2
    else
      echo "ERROR: '$app' is not installed on $host (neither '$local_slug' nor a repository install)." >&2
      echo "       Deploy it first, e.g.: mise run deploy:local $app $host" >&2
    fi
    exit 1
    ;;
  *)
    echo "ERROR: several installed copies of '$slug' found on $host (they would conflict on the app's published port):" >&2
    jq -r '.[] | "       - \(.slug) (version \(.version))"' <<<"$installed" >&2
    echo "       Uninstall all but one first, or pick one explicitly with --slug <slug>." >&2
    exit 1
    ;;
esac

# --- schema safety (the same filter as the deploy/deploy-registry --config migrate flows) --------
# A fresh options POST replaces the whole stored set and silently drops keys unknown to the schema
# (fact: root KNOWLEDGE.md §"Supervisor: option schema quirks") - the filter makes the drops explicit.
filtered=$(ha_filter_options "$options" "$target")
dropped=$(ha_dropped_keys "$options" "$target")
[ "$dropped" != "" ] && echo "-- (dropped, unknown to the app's schema: $dropped)"
if [ "$filtered" = "{}" ]; then
  echo "ERROR: no option key of '$file' matches the schema of $target:" >&2
  echo "       file keys:   $(jq -r 'keys | join(", ")' <<<"$options")" >&2
  echo "       schema keys: $(ha_schema_keys "$target" | jq -r 'join(", ")')" >&2
  echo "       Is the file meant for another app or version?" >&2
  exit 1
fi

if [ "${usage_dry_run:-false}" = "true" ]; then
  echo "-- would POST these options to $target:"
  jq . <<<"$filtered"
  echo "-- dry run: nothing was changed on the device"
  exit 0
fi

# --- apply (the POST replaces the stored set; the current options are user data - back them up first) ---
old=$(ha_app_options "$target")
if [ "$old" != "" ] && [ "$old" != "{}" ]; then
  echo "-- current options backed up locally: $(ha_backup_options "$app" "$old")"
fi
ha_post_options "$target" "$filtered" \
  || {
    echo "ERROR: applying the options failed (the current options are backed up above)" >&2
    exit 1
  }
echo "-- options applied"

if [ "${usage_no_restart:-false}" = "true" ]; then
  echo "-- --no-restart: the options apply at the app's next start"
  exit 0
fi

# --- make the options take effect (options reach a running app only at its next (re)start) -------
state=$(ha_retry 120 ssh "${SSH_OPTS[@]}" "$host" "ha apps info $target --raw-json" | jq -r '.data.state // empty')
case "$state" in
  stopped)
    echo "-- app is stopped - starting it (the options apply at start)"
    ha_app_start "$target"
    ;;
  *)
    echo "-- restarting $target so the options take effect"
    ha_retry 120 ssh "${SSH_OPTS[@]}" "$host" "ha apps restart $target"
    ;;
esac

state=$(ha_ensure_running "$target")
echo "== options applied to $target v$version (state: $state) =="
