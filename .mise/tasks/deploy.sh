#!/usr/bin/env bash
# shellcheck disable=SC2029  # remote commands intentionally embed client-side values ($local_slug)
#MISE description="Deploy an app to a real HAOS device: copy to `/local_apps`, install/update/rebuild as needed and ensure it's running"
#USAGE arg "<app>" help="App to deploy (repo subfolder name)" {
#USAGE   complete run="git ls-files | grep -E '^[^/]+/config.yaml$' | cut -d/ -f1"
#USAGE }
#USAGE arg "<host>" help="SSH target of the Home Assistant OS device, e.g. `root@homeassistant.local` or just `homeassistant.local` (bare host defaults to `root`)"
#USAGE flag "--replace" help="Uninstall an existing repository-installed copy of the app before deploying"
#USAGE flag "--config <mode>" help="""
#USAGE   Fate of the previous app installation's options:
#USAGE   - `migrate`: carry the repository-installed copy's options over to the local install (filtered to the target's schema); only effective with `--replace`
#USAGE   - `reset`: wipe the local install's options; it runs with the app's `config.yaml` default options afterwards
#USAGE   - ***unset*** (default): leave the local install's options untouched unless the app is `--replace`d (options do not survive an uninstall, so the backup file keeps the only copy)
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
version=$(yq -r '.version' "$app/config.yaml")
slug=$(yq -r '.slug' "$app/config.yaml")
local_slug="local_${slug}"

echo "== deploying $app v$version to $host (store slug: $local_slug) =="

# Repository installs get the hashed store slug (fact: root KNOWLEDGE.md §Supervisor: store slugs);
# a second installation would conflict on the published port, so refuse (or --replace). Matching by
# slug suffix instead of reproducing the hash keeps working when the app moves between repositories.
store_apps=$(ssh "${SSH_OPTS[@]}" "$host" 'ha store apps --raw-json' 2>/dev/null || true)
repo_installs=$(echo "$store_apps" | jq -c --arg slug "$slug" --arg local "$local_slug" \
  '[.data.addons[] | select(.installed == true and .slug != $local and ((.slug | split("_")) | last) == $slug)]' 2>/dev/null || true)
if [ "$repo_installs" != "" ] && [ "$repo_installs" != "[]" ]; then
  mapfile -t repo_slugs < <(echo "$repo_installs" | jq -r '.[].slug')
  echo "-- repository-installed copy of '$app' found on $host:"
  echo "$repo_installs" | jq -r '.[] | "  - \(.slug) (installed version \(.version))"'
  if [ "${usage_replace:-false}" = "true" ]; then
    echo "-- --replace given: uninstalling the repository-installed copy first"
    for repo_slug in "${repo_slugs[@]}"; do
      # Options die with the uninstall - back them up first (--config migrate additionally carries them over).
      repo_opts=$(ha_app_options "$repo_slug")
      if [ "$repo_opts" != "" ] && [ "$repo_opts" != "{}" ]; then
        echo "-- options of $repo_slug backed up locally: $(ha_backup_options "$app" "$repo_opts")"
        [ "$CONFIG_MODE" = "migrate" ] && MIGRATE_OPTIONS="$repo_opts"
      fi
      ha_retry 120 ssh "${SSH_OPTS[@]}" "$host" "ha apps uninstall $repo_slug"
    done
  else
    echo "ERROR: two installations would conflict on the app's published port. Uninstall it first, e.g." >&2
    echo "       \`ssh $host 'ha apps uninstall ${repo_slugs[0]}'\` — or re-run with \`--replace\`." >&2
    exit 1
  fi
fi

echo "-- copying app folder to /local_apps (removing existing copy first)"
ssh "${SSH_OPTS[@]}" "$host" 'mkdir -p /local_apps'
ssh "${SSH_OPTS[@]}" "$host" "rm -rf /local_apps/$app"
scp -r "${SSH_OPTS[@]}" "$app" "$host:/local_apps/"

# DEVICE copy only: the Supervisor must build locally instead of pulling GHCR (an image-based app
# would never rebuild) - see .agents/skills/ha-app-device-testing.
if ssh "${SSH_OPTS[@]}" "$host" \
  "sed -i 's|^image:|#image:|' /local_apps/$app/config.yaml && grep -q '^#image:' /local_apps/$app/config.yaml"; then
  echo "-- commented out top-level 'image:' key in the device copy (forces local build)"
else
  echo "-- no top-level 'image:' key in config.yaml (apps without one always build locally)"
fi

echo "-- reloading app store metadata (rescans /local_apps; that only happens on store reload/boot)"
ha_retry 180 ssh "${SSH_OPTS[@]}" "$host" 'ha store reload'

store_info=$(ssh "${SSH_OPTS[@]}" "$host" "ha apps info $local_slug --raw-json" 2>/dev/null || true)
if [ "$store_info" = "" ] || ! echo "$store_info" | jq -e '.result == "ok"' >/dev/null 2>&1; then
  echo "ERROR: $local_slug not found in the app store after reload." >&2
  echo "       Usually the device-side app config is invalid — check the Supervisor logs." >&2
  exit 1
fi

installed_version=$(echo "$store_info" | jq -r '.data.version // empty')
if [ "$installed_version" = "" ]; then
  echo "-- not installed yet: installing"
  ha_retry 900 ssh "${SSH_OPTS[@]}" "$host" "ha apps install $local_slug"
  action="installed"
elif [ "$installed_version" != "$version" ]; then
  echo "-- version changed ($installed_version -> $version): updating"
  ha_retry 900 ssh "${SSH_OPTS[@]}" "$host" "ha apps update $local_slug"
  action="updated"
else
  echo "-- version unchanged ($version): rebuilding image"
  ha_retry 900 ssh "${SSH_OPTS[@]}" "$host" "ha apps rebuild --force $local_slug"
  action="rebuilt"
fi

# --- --config handling -------------------------------------------------------
# Stored options are user data (survive update/rebuild); POSTed options apply at the app's next
# start - restart after posting. Reset posts the config.yaml DEFAULTS, never {} (rejected for
# schemas with required keys; the defaults always satisfy it) - see .agents/skills/ha-app-device-testing.
if [ "$CONFIG_MODE" = "reset" ]; then
  old=$(ha_app_options "$local_slug")
  if [ "$old" != "" ] && [ "$old" != "{}" ]; then
    echo "-- --config reset: previous options backed up locally: $(ha_backup_options "$app" "$old")"
  fi
  ha_post_options "$local_slug" "$(yq -o json '.options' "$app/config.yaml" | jq -c .)" \
    || {
      echo "ERROR: resetting the options failed (the previous options are backed up above)" >&2
      exit 1
    }
  echo "-- --config reset: options set to the app's default options"
  ha_retry 120 ssh "${SSH_OPTS[@]}" "$host" "ha apps restart $local_slug"
fi
if [ "$CONFIG_MODE" = "migrate" ] && [ "${MIGRATE_OPTIONS:-}" != "" ]; then
  echo "-- --config migrate: applying the replaced copy's options (filtered to the app's schema)"
  filtered=$(ha_filter_options "$MIGRATE_OPTIONS" "$local_slug")
  dropped=$(jq -r --argjson keys "$(ha_schema_keys "$local_slug")" \
    'to_entries | map(select(.key as $k | $keys | index($k) | not) | .key) | join(", ")' <<<"$MIGRATE_OPTIONS")
  [ "$dropped" != "" ] && echo "   (dropped, unknown to the app's schema: $dropped)"
  if [ "$filtered" != "{}" ]; then
    ha_post_options "$local_slug" "$filtered" \
      || {
        echo "ERROR: migrating the options failed (the replaced copy's options are backed up above)" >&2
        exit 1
      }
    echo "-- options migrated"
    ha_retry 120 ssh "${SSH_OPTS[@]}" "$host" "ha apps restart $local_slug"
  else
    echo "-- (no options left after filtering - nothing to migrate)"
  fi
fi

state=$(ssh "${SSH_OPTS[@]}" "$host" "ha apps info $local_slug --raw-json" 2>/dev/null \
  | jq -r '.data.state // empty') || state=""
case "$state" in
  started | startup) ;;
  *)
    echo "-- ensuring app is started (install never auto-starts; update/rebuild only restart when it was running)"
    ha_retry 120 ssh "${SSH_OPTS[@]}" "$host" "ha apps start $local_slug"
    ;;
esac
state=$(ssh "${SSH_OPTS[@]}" "$host" "ha apps info $local_slug --raw-json" 2>/dev/null \
  | jq -r '.data.state // empty') || state=""

echo "-- $action $local_slug v$version (state: $state)"

echo "deploy OK"
