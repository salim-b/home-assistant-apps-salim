#!/usr/bin/env bash
#MISE description="Build app images for all supported architectures and assert metadata"
#USAGE arg "[app]" help="App to build (default: all apps)" {
#USAGE   complete run="git ls-files | grep -E '^[^/]+/config.yaml$' | cut -d/ -f1"
#USAGE }
set -euo pipefail
cd "$MISE_PROJECT_ROOT"

# shellcheck disable=SC2124
apps=("${usage_app:-$(git ls-files | grep -E '^[^/]+/config.yaml$' | cut -d/ -f1 | sort -u)}")

native_platform="linux/$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')"
other_platform="linux/$( [ "$native_platform" = "linux/amd64" ] && echo arm64 || echo amd64)"

for app in "${apps[@]}"; do
  echo "== building $app (base: ghcr.io/home-assistant/base) =="
  version=$(yq -r '.version' "$app/config.yaml")
  slug=$(yq -r '.slug' "$app/config.yaml")
  echo "version: $version (slug $slug)"

  echo "-- native ($native_platform), loaded as local/$app:$version"
  docker buildx build --load --tag "local/$app:$version" "$app" 2>&1 | grep -vE "^#[0-9]+ (DONE|CACHED)" | tail -3

  echo "-- cross-check ($other_platform, cache-only)"
  docker buildx build --platform "$other_platform" --output type=cacheonly "$app" >/dev/null 2>&1 \
    || { echo "CROSS BUILD FAILED for $other_platform" >&2; exit 1; }

  echo "-- assertions (what the Dockerfile itself controls; io.hass.* app labels come from CI)"
  docker image inspect "local/$app:$version" --format '{{json .Config.Healthcheck}}' | grep -q '"Test"' \
    || { echo "ASSERT FAILED: no HEALTHCHECK" >&2; exit 1; }
  title="Home Assistant app: $(yq -r '.name' "$app/config.yaml")"
  docker image inspect "local/$app:$version" --format '{{json .Config.Labels}}' | grep -qF "\"org.opencontainers.image.title\":\"$title\"" \
    || { echo "ASSERT FAILED: title label '$title' missing" >&2; exit 1; }
  docker run --rm --entrypoint /bin/sh "local/$app:$version" -c 'test -x /usr/bin/nfsd-healthcheck' 2>/dev/null \
    || { echo "ASSERT FAILED: /usr/bin/nfsd-healthcheck missing" >&2; exit 1; }
  echo "$app OK"
done
echo "build OK"
