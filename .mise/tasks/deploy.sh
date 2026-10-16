#!/usr/bin/env bash
# shellcheck disable=SC2029  # remote commands intentionally embed client-side values ($local_slug)
#MISE description="Deploy an app to a real HAOS device: copy to /local_apps, install/update/rebuild as needed, ensure running"
#USAGE arg "<app>" help="App to deploy (repo subfolder name)" {
#USAGE   complete run="git ls-files | grep -E '^[^/]+/config.yaml$' | cut -d/ -f1"
#USAGE }
#USAGE arg "<host>" help="SSH target of the Home Assistant OS device (bare host defaults to root), e.g. root@homeassistant.local or just homeassistant.local"
#USAGE flag "--replace" help="Uninstall an existing repository-installed copy of this app before deploying"
#USAGE flag "--config <mode>" help="Fate of the options: reset (wipe the local install's options - it runs with the app's config.yaml default options afterwards), migrate (with --replace: carry the repository-installed copy's options over to the local install), or unset = keep (default: the local install's options survive update/rebuild untouched; a replaced copy's options are not carried over - options do not survive an uninstall, so the backup file keeps the only copy)." {
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
case "${CONFIG_MODE}" in
  "" | migrate | reset) ;;
  *)
    echo "ERROR: invalid --config value '${CONFIG_MODE}' (valid: migrate, reset)" >&2
    exit 1
    ;;
esac

# shellcheck source=.mise/tasks/lib/ssh-ha.sh
source "$MISE_PROJECT_ROOT/.mise/tasks/lib/ssh-ha.sh"
wait_supervisor

[ -d "$app" ] || { echo "ERROR: no app directory '$app' in the repo" >&2; exit 1; }
version=$(yq -r '.version' "$app/config.yaml")
slug=$(yq -r '.slug' "$app/config.yaml")
local_slug="local_${slug}"

echo "== deploying $app v$version to $host (store slug: $local_slug) =="

# Apps installed from app repositories get the slug '<repo-hash>_<app-slug>'
# (repo hash = first 8 hex chars of the sha1 over the lowercased repository
# URL, supervisor store/utils.py get_hash_from_repository — f8b2d53d_nfs-server for
# this repo). A second installation alongside the local one would conflict on
# the published port, so refuse (or --replace) when one exists. Matching by
# slug suffix instead of reproducing the hash keeps working when the app
# moves between repositories.
store_apps=$(ssh "${SSH_OPTS[@]}" "$host" 'ha store apps --raw-json' 2>/dev/null || true)
repo_installs=$(echo "$store_apps" | jq -c --arg slug "$slug" --arg local "$local_slug" \
  '[.data.addons[] | select(.installed == true and .slug != $local and ((.slug | split("_")) | last) == $slug)]' 2>/dev/null || true)
if [ -n "$repo_installs" ] && [ "$repo_installs" != "[]" ]; then
  mapfile -t repo_slugs < <(echo "$repo_installs" | jq -r '.[].slug')
  echo "-- repository-installed copy of '$app' found on $host:"
  echo "$repo_installs" | jq -r '.[] | "  - \(.slug) (installed version \(.version))"'
  if [ "${usage_replace:-false}" = "true" ]; then
    echo "-- --replace given: uninstalling the repository-installed copy first"
    for repo_slug in "${repo_slugs[@]}"; do
      # Back the copy's options up before the uninstall (they die with it);
      # --config migrate additionally carries them to the local install.
      repo_opts=$(ha_app_options "$repo_slug")
      if [ -n "$repo_opts" ] && [ "$repo_opts" != "{}" ]; then
        echo "-- options of $repo_slug backed up locally: $(ha_backup_options "$app" "$repo_opts")"
        [ "${CONFIG_MODE}" = "migrate" ] && MIGRATE_OPTIONS="$repo_opts"
      fi
      ha_retry 120 ssh "${SSH_OPTS[@]}" "$host" "ha apps uninstall $repo_slug"
    done
  else
    echo "ERROR: two installations would conflict on the app's published port. Uninstall it first, e.g." >&2
    echo "       ssh $host 'ha apps uninstall ${repo_slugs[0]}' — or re-run with --replace." >&2
    exit 1
  fi
fi

echo "-- copying app folder to /local_apps (removing existing copy first)"
ssh "${SSH_OPTS[@]}" "$host" 'mkdir -p /local_apps'
ssh "${SSH_OPTS[@]}" "$host" "rm -rf /local_apps/$app"
scp -r "${SSH_OPTS[@]}" "$app" "$host:/local_apps/"

# Comment out the top-level `image:` key in the DEVICE copy only: with an
# image key set, the Supervisor would pull that image from GHCR instead of
# building locally from these files (same guidance as the official dev
# docs), and `ha apps rebuild` would refuse an image-based app.
if ssh "${SSH_OPTS[@]}" "$host" \
  "sed -i 's|^image:|#image:|' /local_apps/$app/config.yaml && grep -q '^#image:' /local_apps/$app/config.yaml"; then
  echo "-- commented out top-level 'image:' key in the device copy (forces local build)"
else
  echo "-- no top-level 'image:' key in config.yaml (apps without one always build locally)"
fi

echo "-- reloading app store metadata (rescans /local_apps; that only happens on store reload/boot)"
ha_retry 180 ssh "${SSH_OPTS[@]}" "$host" 'ha store reload'

store_info=$(ssh "${SSH_OPTS[@]}" "$host" "ha apps info $local_slug --raw-json" 2>/dev/null || true)
if [ -z "$store_info" ] || ! echo "$store_info" | jq -e '.result == "ok"' >/dev/null 2>&1; then
  echo "ERROR: $local_slug not found in the app store after reload." >&2
  echo "       Usually the device-side app config is invalid — check the Supervisor logs." >&2
  exit 1
fi

installed_version=$(echo "$store_info" | jq -r '.data.version // empty')
if [ -z "$installed_version" ]; then
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
# The local install's options are user data and survive update/rebuild
# untouched. POSTed options apply at the app's next start - restart after
# posting (idempotent; both apps tolerate restarts fine). Reset posts the
# app's config.yaml DEFAULTS, not {}: a fresh options POST is validated
# against the schema and {} is rejected for schemas with required option
# keys (device-verified 2026-10-16) - the defaults always satisfy it. The
# reset POST runs on every install state: options never survive an
# uninstall (device-verified 2026-10-16), so a fresh install already has
# the defaults (the POST is a no-op there) and an existing install gets
# its options wiped deterministically.
if [ "${CONFIG_MODE}" = "reset" ]; then
  old=$(ha_app_options "$local_slug")
  if [ -n "$old" ] && [ "$old" != "{}" ]; then
    echo "-- --config reset: previous options backed up locally: $(ha_backup_options "$app" "$old")"
  fi
  ha_post_options "$local_slug" "$(yq -o json '.options' "$app/config.yaml" | jq -c .)" ||
    { echo "ERROR: resetting the options failed (the previous options are backed up above)" >&2; exit 1; }
  echo "-- --config reset: options set to the app's default options"
  ha_retry 120 ssh "${SSH_OPTS[@]}" "$host" "ha apps restart $local_slug"
fi
if [ "${CONFIG_MODE}" = "migrate" ] && [ -n "${MIGRATE_OPTIONS:-}" ]; then
  echo "-- --config migrate: applying the replaced copy's options (filtered to the app's schema)"
  filtered=$(ha_filter_options "$MIGRATE_OPTIONS" "$local_slug")
  dropped=$(jq -r --argjson keys "$(ha_schema_keys "$local_slug")" \
    'to_entries | map(select(.key as $k | $keys | index($k) | not) | .key) | join(", ")' <<<"$MIGRATE_OPTIONS")
  [ -n "$dropped" ] && echo "   (dropped, unknown to the app's schema: $dropped)"
  if [ "$filtered" != "{}" ]; then
    ha_post_options "$local_slug" "$filtered" ||
      { echo "ERROR: migrating the options failed (the replaced copy's options are backed up above)" >&2; exit 1; }
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
