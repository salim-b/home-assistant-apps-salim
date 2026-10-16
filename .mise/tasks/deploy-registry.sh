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

# --- derive the repository URL (git remote origin; fallback: config.yaml url:)
repo_url=$(git remote get-url origin 2>/dev/null || true)
if [ -n "$repo_url" ]; then
  case "$repo_url" in
    git@github.com:*) repo_url="https://github.com/${repo_url#git@github.com:}" ;;
  esac
  repo_url=${repo_url%.git}
else
  # https://github.com/<owner>/<repo>/tree/<branch>/<app> -> repo URL
  repo_url=$(yq -r '.url // ""' "$app/config.yaml" | sed 's|/tree/.*||')
fi
[ -n "$repo_url" ] || {
  echo "ERROR: cannot determine the app repository URL (no git remote 'origin', no url in $app/config.yaml)." >&2
  exit 1
}

sup_get() { # sup_get <api-path>: supervisor REST GET (read-only), raw JSON
  ssh "${SSH_OPTS[@]}" "$host" \
    "curl -s -H \"Authorization: Bearer \$SUPERVISOR_TOKEN\" http://supervisor/$1"
}

# --- check the repository is added on the device -----------------------------
repos=$(sup_get store/repositories)
if ! echo "$repos" | jq -e '.result == "ok"' >/dev/null 2>&1; then
  echo "ERROR: could not read the store repositories on $host: $repos" >&2
  exit 1
fi
repo_entry=$(echo "$repos" | jq -c --arg url "$repo_url" \
  '[.data[] | select(((.url // "") | sub("/$";"") | ascii_downcase) == ($url | ascii_downcase))] | .[0] // empty')
if [ -z "$repo_entry" ] || [ "$repo_entry" = "null" ]; then
  echo "ERROR: the app repository is not added on $host:" >&2
  echo "       $repo_url" >&2
  echo "       Add it first, e.g.:  ssh $host 'ha store add $repo_url'" >&2
  echo "       (or in the Home Assistant UI: Settings > Apps > App repositories), then re-run." >&2
  exit 1
fi
repo_slug=$(echo "$repo_entry" | jq -r '.slug')
echo "-- repository on device: $repo_slug ($repo_url)"

# --- discover the store entry + installed copies (one listing) ---------------
# Store/repo installs get the exact slug '<repo-hash>_<app-slug>'; the local
# repo install is 'local_<app-slug>'. Exact matches - no suffix guessing.
store=$(sup_get store/addons)
if ! echo "$store" | jq -e '.result == "ok"' >/dev/null 2>&1; then
  echo "ERROR: could not read the store listing on $host: $store" >&2
  exit 1
fi
store_slug="${repo_slug}_${slug}"

store_entry=$(echo "$store" | jq -c --arg s "$store_slug" \
  '[.data.addons[] | select(.slug == $s)] | .[0] // empty')
if [ -z "$store_entry" ] || [ "$store_entry" = "null" ]; then
  echo "ERROR: the app '${slug}' (expected store slug: $store_slug) is not available in repository $repo_url on $host." >&2
  echo "       Is the app pushed to the repository's default branch? Refresh the store and re-run:" >&2
  echo "         ssh $host 'ha store reload'" >&2
  exit 1
fi
store_version=$(echo "$store_entry" | jq -r '.version_latest')

installed=$(echo "$store" | jq -c --arg store "$store_slug" --arg local "$local_slug" \
  '[.data.addons[] | select(.installed == true and (.slug == $store or .slug == $local))]')
local_installed=$(echo "$installed" | jq -c --arg s "$local_slug" 'map(select(.slug == $s)) | .[0] // empty')
repo_installed=$(echo "$installed" | jq -c --arg s "$store_slug" 'map(select(.slug == $s)) | .[0] // empty')

echo "-- registry: $store_slug (latest version $store_version)"
[ -n "$local_installed" ] && [ "$local_installed" != "null" ] &&
  echo "-- locally installed: $local_slug (version $(echo "$local_installed" | jq -r '.version'))"
[ -n "$repo_installed" ] && [ "$repo_installed" != "null" ] &&
  echo "-- repository-installed: $store_slug (version $(echo "$repo_installed" | jq -r '.version'))"

# --- decide what to do -------------------------------------------------------
if [ -n "$repo_installed" ] && [ "$repo_installed" != "null" ]; then
  if [ -n "$local_installed" ] && [ "$local_installed" != "null" ]; then
    echo "ERROR: both a local and a repository-installed copy exist - they would conflict on the app's published" >&2
    echo "       port. Uninstall one first, e.g.: ssh $host 'ha apps uninstall $local_slug'" >&2
    exit 1
  fi
  installed_version=$(echo "$repo_installed" | jq -r '.version')
  if [ "$installed_version" = "$store_version" ]; then
    echo "-- already the latest registry version ($installed_version); nothing to do"
    exit 0
  fi
  echo "-- updating the registry install ($installed_version -> $store_version)"
  ha_retry 120 ssh "${SSH_OPTS[@]}" "$host" "ha apps update $store_slug"
else
  # Switching from a local copy (or fresh install). Registry installs of a
  # version OLDER than the local copy warn but proceed (an explicit request).
  [ -n "$local_installed" ] && [ "$local_installed" != "null" ] &&
    local_version=$(echo "$local_installed" | jq -r '.version') || local_version=""
  if [ -n "$local_version" ] && [ "$local_version" != "$store_version" ] &&
    [ "$(printf '%s\n' "$local_version" "$store_version" | sort -V | head -1)" != "$store_version" ]; then
    echo "   WARNING: the registry version ($store_version) is OLDER than the locally installed $local_version - proceeding as requested."
  fi

  # --- config migration ------------------------------------------------------
  old_options=""
  if [ -n "$local_version" ]; then
    old_options=$(ha_retry 120 ssh "${SSH_OPTS[@]}" "$host" "ha apps info $local_slug --raw-json" | jq -c '.data.options // empty')
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
    # Back the options up locally before touching the install: a failed
    # registry install must not lose the user's options.
    backup=$(mktemp "${TMPDIR:-/tmp}/deploy-registry-${app}-options-backup.XXXXXX.json")
    printf '%s' "$old_options" >"$backup"
    echo "-- previous options backed up locally: $backup"
    echo "-- uninstalling the local copy ($local_slug)"
    ha_retry 120 ssh "${SSH_OPTS[@]}" "$host" "ha apps uninstall $local_slug"
  fi
  echo "-- installing the registry version ($store_slug, $store_version)"
  ha_retry 900 ssh "${SSH_OPTS[@]}" "$host" "ha apps install $store_slug"

  if [ -n "$old_options" ] && [ "$old_options" != "null" ] && [ -n "${local_version:-}" ]; then
    # Carry the options over, filtered to the target's schema keys: a fresh
    # options POST REPLACES the whole set and the supervisor silently DROPS
    # keys unknown to the target's schema (device-verified 2026-10-16: a full
    # valid set plus bogus keys stores without them, result ok; a set missing
    # required keys is rejected) - while keys REMOVED from the schema that are
    # already STORED are inert (one-line warning on each read). The filter
    # makes the drops explicit and reported instead of silent.
    echo "-- migrating the previous options (filtered to the target schema)"
    schema_keys=$(ha_retry 120 ssh "${SSH_OPTS[@]}" "$host" "ha apps info $store_slug --raw-json" |
      jq -c 'if (.data.schema | type) == "array" then [.data.schema[] | .name] else [.data.schema | keys[]] end')
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
        echo "       (the app is installed but runs with defaults; the previous options are in $backup)" >&2
        exit 1
      fi
      echo "-- options migrated"
    fi
  fi
fi

# --- ensure running ----------------------------------------------------------
# 'ha apps install' never auto-starts the app (updates/rebuilds only restart
# when it was running): start it when the state check finds it not running,
# then verify again.
sleep 3
state=$(ha_retry 120 ssh "${SSH_OPTS[@]}" "$host" "ha apps info $store_slug --raw-json" | jq -r '.data.state // empty')
case "$state" in
  started | startup) ;;
  *)
    echo "-- app is not running (state: $state) - starting it"
    ha_retry 120 ssh "${SSH_OPTS[@]}" "$host" "ha apps start $store_slug"
    sleep 10
    state=$(ha_retry 120 ssh "${SSH_OPTS[@]}" "$host" "ha apps info $store_slug --raw-json" | jq -r '.data.state // empty')
    case "$state" in
      started | startup) ;;
      *)
        echo "WARNING: the app state is '$state' even after a start attempt - check the app log:" >&2
        echo "         ssh $host 'ha apps logs $store_slug'" >&2
        exit 1
        ;;
    esac
    ;;
esac
final_version=$(ha_retry 120 ssh "${SSH_OPTS[@]}" "$host" "ha apps info $store_slug --raw-json" | jq -r '.data.version')
echo "== $app now runs the registry version $final_version (state: $state) =="
