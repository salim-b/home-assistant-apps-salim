#!/usr/bin/env bash
#MISE description="Build app container images for all supported architectures and assert metadata"
#USAGE arg "[app]" help="App to build (default: all apps)" {
#USAGE   complete run="git ls-files | grep -E '^[^/]+/config.yaml$' | cut -d/ -f1"
#USAGE }
#USAGE flag "--rebuild" help="Rebuild even when the image is newer than every input file (make-style freshness check)"

set -euo pipefail

if [ "${usage_app:-}" != "" ]; then
  apps=("$usage_app")
else
  mapfile -t apps < <(git ls-files | grep -E '^[^/]+/config.yaml$' | cut -d/ -f1 | sort -u)
fi

native_platform="linux/$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')"
other_platform="linux/$([ "$native_platform" = "linux/amd64" ] && echo arm64 || echo amd64)"

## Per-app build stamps (.gitignored): the freshness reference touched after each successful build
stamps=".mise/build-stamps"
mkdir -p "$stamps"

for app in "${apps[@]}"; do
  version=$(yq -r '.version' "$app/config.yaml")
  slug=$(yq -r '.slug' "$app/config.yaml")
  ## make-style freshness: the whole app dir is the build context, so any file newer than the last
  ## successful build's stamp means stale. The stamp - not the image's .Created - is the reference
  ## point: buildx rebuilds unchanged content from cache into the SAME image (docker keeps the old
  ## .Created), so an mtime-vs-image check would never converge. A doc-only edit may over-trigger;
  ## the rebuild is then all-CACHED, costing seconds. --rebuild bypasses the check.
  if [ "${usage_rebuild:-false}" != "true" ] \
    && docker image inspect "local/$app:$version" >/dev/null 2>&1 \
    && [ -f "$stamps/$app" ] \
    && [ "$(find "$app" -type f -newer "$stamps/$app" -print -quit 2>/dev/null)" = "" ]; then
    echo "== $app $version up to date, skipping =="
    continue
  fi
  echo "== building $app (base: ghcr.io/home-assistant/base) =="
  echo "version: $version (slug $slug)"

  echo "-- native ($native_platform), loaded as local/$app:$version"
  docker buildx build --load --tag "local/$app:$version" "$app" 2>&1 | grep -vE "^#[0-9]+ (DONE|CACHED)" | tail -3

  echo "-- cross-check ($other_platform, cache-only)"
  docker buildx build --platform "$other_platform" --output type=cacheonly "$app" >/dev/null 2>&1 \
    || {
      echo "CROSS BUILD FAILED for $other_platform" >&2
      exit 1
    }

  echo "-- assertions (what the Dockerfile itself controls; io.hass.* app labels come from CI)"
  docker image inspect "local/$app:$version" --format '{{json .Config.Healthcheck}}' | grep -q '"Test"' \
    || {
      echo "ASSERT FAILED: no HEALTHCHECK" >&2
      exit 1
    }
  title="Home Assistant app: $(yq -r '.name' "$app/config.yaml")"
  docker image inspect "local/$app:$version" --format '{{json .Config.Labels}}' | grep -qF "\"org.opencontainers.image.title\":\"$title\"" \
    || {
      echo "ASSERT FAILED: title label '$title' missing" >&2
      exit 1
    }
  echo "$app OK"
  touch "$stamps/$app" # only a fully successful build+check cycle stamps the app as fresh
done
echo "build OK"
