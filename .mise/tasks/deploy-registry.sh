#!/usr/bin/env bash
# shellcheck disable=SC2029  # remote commands intentionally embed client-side values
#MISE description="Switch a device to the app's latest registry/store version: tear down any locally installed copy, optionally migrate its config (opt-in)"
#USAGE arg "<app>" help="App to switch to the registry version (repo subfolder name)" {
#USAGE   complete run="git ls-files | grep -E '^[^/]+/config.yaml$' | cut -d/ -f1"
#USAGE }
#USAGE arg "<host>" help="SSH target of the Home Assistant OS device (bare host defaults to root), e.g. root@homeassistant.local or just homeassistant.local"
#USAGE flag "--migrate-config" help="Carry the previous install's options to the registry install (key-filtered to the target's schema)"
#USAGE flag "--discard-config" help="Drop the previous install's options when switching"
set -euo pipefail
cd "$MISE_PROJECT_ROOT"

app="${usage_app?}"
host="${usage_host?}"
# Bare host (no user@) defaults to root: HAOS device access is root-based
case "$host" in *@*) ;; *) host="root@$host" ;; esac
SSH_OPTS=(-o ConnectTimeout=10)

# shellcheck source=.mise/tasks/lib/ssh-ha.sh
source "$MISE_PROJECT_ROOT/.mise/tasks/lib/ssh-ha.sh"
wait_supervisor

[ -d "$app" ] || { echo "ERROR: no app directory '$app' in the repo" >&2; exit 1; }
slug=$(yq -r '.slug' "$app/config.yaml")
local_slug="local_${slug}"

echo "== switching $app to the registry version on $host =="

ha() { # ha <args...> via ssh (retrying transient supervisor failures)
  ha_retry 120 ssh "${SSH_OPTS[@]}" "$host" "ha $*"
}

# --- discover the installs --------------------------------------------------
# Store/repo installs get the slug '<repo-hash>_<app-slug>'; matching by
# suffix keeps working when the app moves between repositories (the same
# approach the deploy task uses). The repo hash (supervisor store/utils.py
# get_hash_from_repository) could be derived from the repository URL, but
# discovery from the device's store listing needs no URL-normalization
# guesses.
store_apps=$(ha store apps --raw-json | jq -c '.data')

store_entry=$(echo "$store_apps" | jq -c --arg slug "$slug" \
  '[.addons[] | select((.slug | split("_")) | last) == $slug] | .[0] // empty')
if [ -z "$store_entry" ] || [ "$store_entry" = "null" ]; then
  echo "ERROR: no app with slug '$slug' in any app repository on $host." >&2
  echo "       Add this repository to the device's app repositories first (or check the slug)." >&2
  exit 1
fi
store_slug=$(echo "$store_entry" | jq -r '.slug')
store_version=$(echo "$store_entry" | jq -r '.version')

installed=$(echo "$store_apps" | jq -c --arg slug "$slug" --arg local "$local_slug" \
  '[.addons[] | select(.installed == true and ((.slug | split("_")) | last) == $slug)]')
local_installed=$(echo "$installed" | jq -c --arg s "$local_slug" '[.[] | select(.slug == $s)] | .[0] // empty')
repo_installed=$(echo "$installed" | jq -c '[.[] | select(.slug != "'"$local_slug"'")] | .[0] // empty')

echo "-- store: $store_slug (latest version $store_version)"
if [ -n "$local_installed" ] && [ "$local_installed" != "null" ]; then
  echo "-- locally installed: $(echo "$local_installed" | jq -r .slug) (version $(echo "$local_installed" | jq -r .version))"
fi
if [ -n "$repo_installed" ] && [ "$repo_installed" != "null" ]; then
  echo "-- repository-installed: $(echo "$repo_installed" | jq -r .slug) (version $(echo "$repo_installed" | jq -r .version))"
fi

# --- decide what to do ------------------------------------------------------
if [ -n "$repo_installed" ] && [ "$repo_installed" != "null" ]; then
  target_slug=$(echo "$repo_installed" | jq -r .slug)
  target_version=$(echo "$repo_installed" | jq -r .version)
  if [ -n "$local_installed" ] && [ "$local_installed" != "null" ]; then
    echo "ERROR: both a local and a repository-installed copy exist - they would conflict on the app's published" >&2
    echo "       port. Uninstall one first, e.g.: ssh $host 'ha apps uninstall $(echo "$local_installed" | jq -r .slug)'" >&2
    exit 1
  fi
  if [ "$target_version" = "$store_version" ]; then
    echo "-- already the latest registry version ($target_version); nothing to do"
    exit 0
  fi
  echo "-- updating the registry install ($target_version -> $store_version)"
  ha apps update "$target_slug"
else
  # Switching from a local copy (or fresh install). Registry installs of a
  # version OLDER than the local copy warn but proceed (an explicit request).
  [ -n "$local_installed" ] && [ "$local_installed" != "null" ] &&
    local_version=$(echo "$local_installed" | jq -r .version) || local_version=""
  if [ -n "$local_version" ] && [ "$(printf '%s\n' "$local_version" "$store_version" | sort -V | head -1)" != "$store_version" ] &&
    [ "$local_version" != "$store_version" ]; then
    echo "   WARNING: the registry version ($store_version) is OLDER than the locally installed $local_version - proceeding as requested."
  fi

  # --- config migration -----------------------------------------------------
  old_options=""
  if [ -n "$local_version" ]; then
    old_options=$(ha apps info "$local_slug" --raw-json | jq -c '.data.options // empty')
    if [ -n "$old_options" ] && [ "$old_options" != "null" ] && [ "$old_options" != "{}" ]; then
      if [ "${usage_migrate_config:-false}" != "true" ] && [ "${usage_discard_config:-false}" != "true" ]; then
        echo "ERROR: the locally installed copy has options (user data). Refusing to discard them silently:" >&2
        echo "       re-run with --migrate-config to carry them to the registry install," >&2
        echo "       or with --discard-config to drop them." >&2
        exit 1
      fi
      if [ "${usage_discard_config:-false}" = "true" ]; then
        echo "-- discarding the local copy's options (--discard-config)"
        old_options=""
      fi
    else
      old_options=""
    fi
  fi

  if [ -n "$local_version" ]; then
    echo "-- uninstalling the local copy ($local_slug)"
    ha apps uninstall "$local_slug"
  fi
  echo "-- installing the registry version ($store_slug, $store_version)"
  ha_retry 900 ssh "${SSH_OPTS[@]}" "$host" "ha apps install $store_slug"

  if [ -n "$old_options" ] && [ "$old_options" != "null" ]; then
    # Carry the options over, filtered to the target's schema keys: options
    # REMOVED from a newer app version's schema are inert when already
    # STORED (the supervisor only warns), but a fresh options POST containing
    # unknown keys is rejected - so migrate only what the target still knows.
    echo "-- migrating the previous options (filtered to the target schema)"
    schema_keys=$(ha apps info "$store_slug" --raw-json | jq -c '[.data.schema | keys[]]')
    filtered=$(jq -c --argjson keys "$schema_keys" 'with_entries(select(.key as $k | $keys | index($k)))' <<<"$old_options")
    dropped=$(jq -r --argjson keys "$schema_keys" 'to_entries | map(select(.key as $k | $keys | index($k) | not) | .key) | join(", ")' <<<"$old_options")
    [ -n "$dropped" ] && echo "   (dropped, unknown to the target's schema: $dropped)"
    if [ "$filtered" = "{}" ]; then
      echo "-- (no options left after filtering - nothing to migrate)"
    else
      result=$(printf '{"options": %s}' "$filtered" | ssh "${SSH_OPTS[@]}" "$host" \
        "curl -s -H \"Authorization: Bearer \$SUPERVISOR_TOKEN\" -H 'Content-Type: application/json' \
           -X POST --data-binary @- http://supervisor/addons/$store_slug/options")
      if ! echo "$result" | jq -e '.result == "ok"' >/dev/null 2>&1; then
        echo "ERROR: the supervisor rejected the migrated options: $result" >&2
        echo "       (the app is installed but may run with defaults; compare and POST the options manually)" >&2
        exit 1
      fi
      echo "-- options migrated"
    fi
  fi
fi

# --- ensure running ---------------------------------------------------------
sleep 3
state=$(ha apps info "$store_slug" --raw-json | jq -r '.data.state // empty')
case "$state" in
  started | startup) ;;
  *)
    echo "WARNING: the app state is '$state' (expected 'started') - check the app log:" >&2
    echo "         ssh $host 'ha apps logs $store_slug'" >&2
    exit 1
    ;;
esac
final_version=$(ha apps info "$store_slug" --raw-json | jq -r '.data.version')
echo "== $app now runs the registry version $final_version (state: $state) =="
