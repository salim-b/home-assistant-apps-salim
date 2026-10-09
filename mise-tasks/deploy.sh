#!/usr/bin/env bash
# shellcheck disable=SC2029  # remote commands intentionally embed client-side values ($local_slug)
#MISE description="Deploy an app to a real HAOS device: copy to /local_apps, install/update/rebuild as needed, ensure running"
#USAGE arg "<app>" help="App to deploy (repo subfolder name)" {
#USAGE   complete run="git ls-files | grep -E '^[^/]+/config.yaml$' | cut -d/ -f1"
#USAGE }
#USAGE arg "<host>" help="SSH target of the Home Assistant OS device, e.g. root@192.168.1.11"
#USAGE flag "--replace" help="Uninstall an existing repository-installed copy of this app before deploying"
#USAGE flag "--test-shares" help="Apply the app's test shares (mise-tasks/test/shares/<app>.yaml) to the device app options; test:live restores them afterwards"
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
  echo "-- repository-installed copy of '$app' found on $host:"
  echo "$repo_installs" | jq -r '.[] | "  - \(.slug) (installed version \(.version))"'
  if [ "${usage_replace:-false}" = "true" ]; then
    echo "-- --replace given: uninstalling the repository-installed copy first"
    for repo_slug in "${repo_slugs[@]}"; do
      ssh "${SSH_OPTS[@]}" "$host" "ha apps uninstall $repo_slug"
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

# --test-shares: apply the app's test shares (mise-tasks/test/shares/<app>.yaml)
# to the app's options on the device, so the test:live roundtrip can exercise
# the full export surface. This goes through the supervisor options API on
# purpose: an installed app's options are user data and are NOT refreshed from
# config.yaml defaults by update/rebuild, so editing the device copy of
# config.yaml would be a no-op.
if [ "${usage_test_shares:-false}" = "true" ]; then
  shares_file="mise-tasks/test/shares/$app.yaml"
  [ -f "$shares_file" ] || { echo "ERROR: no test shares file '$shares_file'" >&2; exit 1; }
  echo "-- applying test shares ($shares_file) to the app options"

  current=$(ssh "${SSH_OPTS[@]}" "$host" "ha apps info $local_slug --raw-json" 2>/dev/null \
    | jq -c '.data.options // empty')
  [ -n "$current" ] || { echo "ERROR: could not read the app's current options on $host" >&2; exit 1; }

  # Back up the original options next to the app folder for the test:live
  # restore step; the next deploy wipes it together with the app folder.
  printf '%s' "$current" | ssh "${SSH_OPTS[@]}" "$host" \
    "cat > /local_apps/$app/.test-shares-original.json"

  test_shares=$(yq -o json '.shares' "$shares_file")
  new_options=$(jq -c --argjson shares "$test_shares" '.shares = $shares' <<<"$current")
  result=$(printf '%s' "$new_options" | ssh "${SSH_OPTS[@]}" "$host" \
    "curl -s -H \"Authorization: Bearer \$SUPERVISOR_TOKEN\" -H 'Content-Type: application/json' \
       -X POST --data-binary @- http://supervisor/addons/$local_slug/options")
  if ! echo "$result" | jq -e '.result == "ok"' >/dev/null 2>&1; then
    echo "ERROR: the supervisor rejected the test options: $result" >&2
    exit 1
  fi

  # The app validates that share paths exist as directories on the host;
  # create missing ones and hand the writable ones to the squashed uid
  # (default_uid 1000) so the roundtrip can write into them.
  while IFS=$'\t' read -r spath sopts; do
    [ -n "$spath" ] || continue
    case ",$sopts," in
      *,rw,*)
        ssh "${SSH_OPTS[@]}" "$host" "mkdir -p '$spath' && chown 1000:1000 '$spath'"
        ;;
      *)
        ssh "${SSH_OPTS[@]}" "$host" "mkdir -p '$spath'"
        ;;
    esac
  done < <(yq -r '.shares[] | [.path, .options] | @tsv' "$shares_file")

  ssh "${SSH_OPTS[@]}" "$host" "ha apps restart $local_slug"
  echo "-- test shares active; original options saved on the device at"
  echo "   /local_apps/$app/.test-shares-original.json (test:live restores them after the run)"
fi
echo "deploy OK"
