#!/usr/bin/env bash
# shellcheck disable=SC2029  # remote commands intentionally embed client-side values ($local_slug)
#MISE description="Deploy an app to a real HAOS device: copy to /local_apps, install/update/rebuild as needed, ensure running"
#USAGE arg "<app>" help="App to deploy (repo subfolder name)" {
#USAGE   complete run="git ls-files | grep -E '^[^/]+/config.yaml$' | cut -d/ -f1"
#USAGE }
#USAGE arg "<host>" help="SSH target of the Home Assistant OS device, e.g. root@192.168.1.11"
#USAGE flag "--replace" help="Uninstall an existing repository-installed copy of this app before deploying"
set -euo pipefail
cd "$MISE_PROJECT_ROOT"

app="${usage_app?}"
host="${usage_host?}"
SSH_OPTS=(-o ConnectTimeout=10)

[ -d "$app" ] || { echo "ERROR: no app directory '$app' in the repo" >&2; exit 1; }
version=$(yq -r '.version' "$app/config.yaml")
slug=$(yq -r '.slug' "$app/config.yaml")
local_slug="local_${slug}"

echo "== deploying $app v$version to $host (store slug: $local_slug) =="

# Apps installed from app repositories get the slug '<repo-hash>_<app-slug>'
# (repo hash = first 8 hex chars of the sha1 over the lowercased repository
# URL, supervisor store/utils.py get_hash_from_repository — f8b2d53d_nfs for
# this repo). A second installation alongside the local one would conflict on
# the published port, so refuse (or --replace) when one exists. Matching by
# slug suffix instead of reproducing the hash keeps working when the app
# moves between repositories.
store_apps=$(ssh "${SSH_OPTS[@]}" "$host" 'ha store apps --raw-json' 2>/dev/null || true)
repo_installs=$(echo "$store_apps" | jq -c --arg slug "$slug" --arg local "$local_slug" \
  '[.data.addons[] | select(.installed == true and .slug != $local and ((.slug | split("_")) | last) == $slug)]' 2>/dev/null || true)
if [ -n "$repo_installs" ] && [ "$repo_installs" != "[]" ]; then
  mapfile -t repo_slugs < <(echo "$repo_installs" | jq -r '.[].slug')
  echo "ERROR: '$app' is already installed on $host from an app repository:" >&2
  echo "$repo_installs" | jq -r '.[] | "  - \(.slug) (installed version \(.version))"' >&2
  if [ "${usage_replace:-false}" = "true" ]; then
    echo "-- --replace given: uninstalling the repository-installed copy first"
    for repo_slug in "${repo_slugs[@]}"; do
      ssh "${SSH_OPTS[@]}" "$host" "ha apps uninstall $repo_slug"
    done
  else
    echo "       Two installations would conflict on the app's published port. Uninstall it first, e.g." >&2
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
ssh "${SSH_OPTS[@]}" "$host" 'ha store reload'

store_info=$(ssh "${SSH_OPTS[@]}" "$host" "ha apps info $local_slug --raw-json" 2>/dev/null || true)
if [ -z "$store_info" ] || ! echo "$store_info" | jq -e '.result == "ok"' >/dev/null 2>&1; then
  echo "ERROR: $local_slug not found in the app store after reload." >&2
  echo "       Usually the device-side app config is invalid — check the Supervisor logs." >&2
  exit 1
fi

installed_version=$(echo "$store_info" | jq -r '.data.version // empty')
if [ -z "$installed_version" ]; then
  echo "-- not installed yet: installing"
  ssh "${SSH_OPTS[@]}" "$host" "ha apps install $local_slug"
  action="installed"
elif [ "$installed_version" != "$version" ]; then
  echo "-- version changed ($installed_version -> $version): updating"
  ssh "${SSH_OPTS[@]}" "$host" "ha apps update $local_slug"
  action="updated"
else
  echo "-- version unchanged ($version): rebuilding image"
  ssh "${SSH_OPTS[@]}" "$host" "ha apps rebuild --force $local_slug"
  action="rebuilt"
fi

state=$(ssh "${SSH_OPTS[@]}" "$host" "ha apps info $local_slug --raw-json" 2>/dev/null \
  | jq -r '.data.state // empty')
case "$state" in
  started | startup) ;;
  *)
    echo "-- ensuring app is started (install never auto-starts; update/rebuild only restart when it was running)"
    ssh "${SSH_OPTS[@]}" "$host" "ha apps start $local_slug"
    ;;
esac
state=$(ssh "${SSH_OPTS[@]}" "$host" "ha apps info $local_slug --raw-json" 2>/dev/null \
  | jq -r '.data.state // empty')

echo "-- $action $local_slug v$version (state: $state)"
echo "deploy OK"
