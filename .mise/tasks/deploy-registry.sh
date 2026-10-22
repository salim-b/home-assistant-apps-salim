#!/usr/bin/env bash
# shellcheck disable=SC2029  # remote commands intentionally embed client-side values
#MISE description="Switch a HAOS device to the app's latest registry/store version and tear down any locally installed copy"
#USAGE arg "<app>" help="App to switch to the registry version (repo subfolder name)" {
#USAGE   complete run="git ls-files | grep -E '^[^/]+/config.yaml$' | cut -d/ -f1"
#USAGE }
#USAGE arg "<host>" help="SSH target of the Home Assistant OS device (bare host defaults to `root`), e.g. `root@homeassistant.local` or just `homeassistant.local`"
#USAGE flag "--config <mode>" help="""
#USAGE   Fate of the previous app installation's options:
#USAGE   - `migrate`: carry the local copy's options over to the registry install (filtered to the target's schema); only effective if the app was installed locally previously (a registry install update keeps its options anyway)
#USAGE   - `reset`: wipe the registry install's options, making the app run with the repo's `config.yaml` defaults
#USAGE   - ***unset*** (default): the local copy's options are *not* carried over to the registry install (stored options do not survive an uninstall, but are archived to a local backup file, path printed); a registry install update preserves its options
#USAGE """ {
#USAGE   choices "migrate" "reset"
#USAGE }

set -euo pipefail
cd "$MISE_PROJECT_ROOT"

app="${usage_app?}"
host="${usage_host?}"
# Bare host (no user@) defaults to root: HAOS device access is root-based
case "$host" in *@*) ;; *) host="root@$host" ;; esac
SSH_OPTS=(-o ConnectTimeout=10)

CONFIG_MODE="${usage_config:-}"
case "$CONFIG_MODE" in
  "" | migrate | reset) ;;
  *)
    echo "ERROR: invalid --config value '${CONFIG_MODE}' (valid: migrate, reset)" >&2
    exit 1
    ;;
esac

# shellcheck source=.mise/tasks/lib/ssh-ha.sh
source "$MISE_PROJECT_ROOT/.mise/tasks/lib/ssh-ha.sh"
wait_supervisor

[ -d "$app" ] || {
  echo "ERROR: no app directory '$app' in the repo" >&2
  exit 1
}
slug=$(yq -r '.slug' "$app/config.yaml")
local_slug="local_${slug}"

echo "== switching $app to the registry version on $host =="

# --- derive the repository URL (git remote origin; fallback: config.yaml url:)
repo_url=$(git remote get-url origin 2>/dev/null || true)
if [ "$repo_url" != "" ]; then
  case "$repo_url" in
    git@github.com:*) repo_url="https://github.com/${repo_url#git@github.com:}" ;;
  esac
  repo_url=${repo_url%.git}
else
  # https://github.com/<owner>/<repo>/tree/<branch>/<app> -> repo URL
  repo_url=$(yq -r '.url // ""' "$app/config.yaml" | sed 's|/tree/.*||')
fi
[ "$repo_url" != "" ] || {
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
if [ "$repo_entry" = "" ] || [ "$repo_entry" = "null" ]; then
  echo "ERROR: the app repository is not added on $host:" >&2
  echo "       $repo_url" >&2
  echo "       Add it first, e.g.:  ssh $host 'ha store add $repo_url'" >&2
  echo "       (or in the Home Assistant UI: Settings > Apps > App repositories), then re-run." >&2
  exit 1
fi
repo_slug=$(echo "$repo_entry" | jq -r '.slug')
echo "-- repository on device: $repo_slug ($repo_url)"

# --- discover the store entry + installed copies (one listing) ---------------
# Store installs get the exact hashed slug '<repo-hash>_<app-slug>', the local one 'local_<app-slug>'
# (fact: root KNOWLEDGE.md §Supervisor: store slugs) - exact matches, no suffix guessing.
store=$(sup_get store/addons)
if ! echo "$store" | jq -e '.result == "ok"' >/dev/null 2>&1; then
  echo "ERROR: could not read the store listing on $host: $store" >&2
  exit 1
fi
store_slug="${repo_slug}_${slug}"

store_entry=$(echo "$store" | jq -c --arg s "$store_slug" \
  '[.data.addons[] | select(.slug == $s)] | .[0] // empty')
if [ "$store_entry" = "" ] || [ "$store_entry" = "null" ]; then
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
[ "$local_installed" != "" ] && [ "$local_installed" != "null" ] \
  && echo "-- locally installed: $local_slug (version $(echo "$local_installed" | jq -r '.version'))"
[ "$repo_installed" != "" ] && [ "$repo_installed" != "null" ] \
  && echo "-- repository-installed: $store_slug (version $(echo "$repo_installed" | jq -r '.version'))"

# The app's config.yaml default options: the reset target ({} would be rejected for schemas with
# required option keys - the defaults always satisfy the schema).
default_options=$(yq -o json '.options' "$app/config.yaml" | jq -c .)

# --- decide what to do -------------------------------------------------------
if [ "$repo_installed" != "" ] && [ "$repo_installed" != "null" ]; then
  if [ "$local_installed" != "" ] && [ "$local_installed" != "null" ]; then
    echo "ERROR: both a local and a repository-installed copy exist - they would conflict on the app's published" >&2
    echo "       port. Uninstall one first, e.g.: ssh $host 'ha apps uninstall $local_slug'" >&2
    exit 1
  fi
  installed_version=$(echo "$repo_installed" | jq -r '.version')
  if [ "$installed_version" = "$store_version" ] && [ "$CONFIG_MODE" != "reset" ]; then
    echo "-- already the latest registry version ($installed_version); nothing to do"
    exit 0
  fi
  if [ "$installed_version" = "$store_version" ]; then
    echo "-- already the latest registry version ($installed_version); applying --config reset"
  else
    echo "-- updating the registry install ($installed_version -> $store_version)"
    ha_retry 120 ssh "${SSH_OPTS[@]}" "$host" "ha apps update $store_slug"
  fi
  if [ "$CONFIG_MODE" = "reset" ]; then
    old=$(ha_app_options "$store_slug")
    if [ "$old" != "" ] && [ "$old" != "{}" ]; then
      echo "-- previous options backed up locally: $(ha_backup_options "$app" "$old")"
      ha_post_options "$store_slug" "$default_options" \
        || {
          echo "ERROR: resetting the options failed (the previous options are backed up above)" >&2
          exit 1
        }
      echo "-- --config reset: options set to the app's default options"
      ha_retry 120 ssh "${SSH_OPTS[@]}" "$host" "ha apps restart $store_slug"
    else
      echo "-- --config reset: the install has no options - nothing to reset"
    fi
  fi
else
  # Switching from a local copy (or fresh install); an OLDER registry version warns but proceeds (explicit request).
  [ "$local_installed" != "" ] && [ "$local_installed" != "null" ] \
    && local_version=$(echo "$local_installed" | jq -r '.version') || local_version=""
  if [ "$local_version" != "" ] && [ "$local_version" != "$store_version" ] \
    && [ "$(printf '%s\n' "$local_version" "$store_version" | sort -V | head -1)" != "$store_version" ]; then
    echo "   WARNING: the registry version ($store_version) is OLDER than the locally installed $local_version - proceeding as requested."
  fi

  # --- the previous options' fate (--config) ---------------------------------
  old_options=""
  backup_note="none"
  if [ "$local_version" != "" ]; then
    old_options=$(ha_app_options "$local_slug")
    if [ "$old_options" != "" ] && [ "$old_options" != "{}" ] && [ "$old_options" != "null" ]; then
      backup_note="backed up locally: $(ha_backup_options "$app" "$old_options")"
      echo "-- previous options backed up locally: ${backup_note#backed up locally: }"
    else
      old_options=""
    fi
  fi
  case "$CONFIG_MODE" in
    migrate)
      [ "$old_options" != "" ] || echo "-- (no previous options to migrate)"
      ;;
    reset)
      ## The reset POST runs after the install below: a fresh install already carries the app's default
      ## options (stored options never survive an uninstall) - no-op there, deterministic wipe otherwise.
      echo "-- --config reset: the registry install will run with the app's default options (previous options: $backup_note)"
      old_options=""
      ;;
    *)
      ## unset = keep (the default): an UPDATE preserves the options; on a local->store switch they are
      ## NOT carried over (options never survive an uninstall - only the backup file keeps a copy).
      [ "$old_options" != "" ] \
        && echo "-- options not carried over (options do not survive the uninstall; $backup_note)"
      old_options=""
      ;;
  esac

  if [ "$local_version" != "" ]; then
    echo "-- uninstalling the local copy ($local_slug)"
    ha_retry 120 ssh "${SSH_OPTS[@]}" "$host" "ha apps uninstall $local_slug"
  fi
  echo "-- installing the registry version ($store_slug, $store_version)"
  ha_retry 900 ssh "${SSH_OPTS[@]}" "$host" "ha apps install $store_slug"

  if [ "$CONFIG_MODE" = "migrate" ] && [ "$old_options" != "" ]; then
    echo "-- migrating the previous options (filtered to the target schema)"
    filtered=$(ha_filter_options "$old_options" "$store_slug")
    dropped=$(jq -r --argjson keys "$(ha_schema_keys "$store_slug")" \
      'to_entries | map(select(.key as $k | $keys | index($k) | not) | .key) | join(", ")' <<<"$old_options")
    [ "$dropped" != "" ] && echo "   (dropped, unknown to the target's schema: $dropped)"
    if [ "$filtered" = "{}" ]; then
      echo "-- (no options left after filtering - nothing to migrate)"
    else
      ha_post_options "$store_slug" "$filtered" \
        || {
          echo "ERROR: migrating the options failed (the previous options are backed up above)" >&2
          exit 1
        }
      echo "-- options migrated"
    fi
  fi
  if [ "$CONFIG_MODE" = "reset" ]; then
    echo "-- --config reset: posting the app's default options"
    ha_post_options "$store_slug" "$default_options" \
      || {
        echo "ERROR: resetting the options failed (the previous options are backed up above)" >&2
        exit 1
      }
  fi
fi

# --- ensure running ----------------------------------------------------------
# 'ha apps install' never auto-starts (updates/rebuilds only restart when it was running):
# start it when the state check finds it not running, then verify again.
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
