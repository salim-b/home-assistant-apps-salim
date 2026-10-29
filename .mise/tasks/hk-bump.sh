#!/usr/bin/env bash
#MISE description="Bump hk tool version and config file in one change (`mise.toml` tools pin, `hk.pkl` package imports and `mise.lock`)"
#USAGE arg "[version]" help="Target hk version, e.g. `2.10.0` (`v` prefix tolerated). Defaults to the latest stable GitHub release."
#USAGE flag "--dry-run" help="Print the planned changes without writing files"

set -euo pipefail

target="${usage_version:-}"
dry_run="${usage_dry_run:-false}"
api="https://api.github.com/repos/jdx/hk/releases"

## Resolve the target version: explicit argument, else the latest stable release
## (GitHub's releases/latest endpoint already excludes drafts and prereleases).
if [ "$target" = "" ]; then
  echo "No version given - looking up the latest stable hk release"
  target=$(
    curl -fsSL --max-time 30 "$api/latest" | jq -r .tag_name
  ) || {
    echo "ERROR: could not query GitHub for the latest hk release" >&2
    exit 1
  }
fi
if [ "$target" = "null" ]; then
  echo "ERROR: GitHub returned no latest hk release" >&2
  exit 1
fi
target=${target#v}
if ! [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: '$target' is not a version of the form X.Y.Z" >&2
  exit 1
fi

## Current pin: the two hk.pkl package lines must agree with each other ...
pins_str=$(rg -o --no-filename 'releases/download/v[0-9]+\.[0-9]+\.[0-9]+/hk@[0-9]+\.[0-9]+\.[0-9]+#' hk.pkl | sort -u)
mapfile -t pins <<<"$pins_str"
if [ "${#pins[@]}" -ne 1 ]; then
  echo "ERROR: hk.pkl's amends and import lines pin different versions (${pins[*]}) - reconcile them manually first" >&2
  exit 1
fi
old=${pins[0]}
old=${old#releases/download/v}
old=${old%%/*}
## ... and with the mise.toml [tools] pin (its shape is asserted verbatim so the
## sigstore-verifying `workflow = "release.yml"` attribute survives the bump).
pin_line="hk = { version = \"$old\", workflow = \"release.yml\" }"
if [ "$(rg -F -c "$pin_line" mise.toml || true)" != "1" ]; then
  echo "ERROR: mise.toml has no single '$pin_line' - reconcile it with the hk.pkl pin ($old) manually first" >&2
  exit 1
fi

if [ "$old" = "$target" ]; then
  echo "hk is already pinned to $target - nothing to do"
  exit 0
fi

## The hk.pkl imports fetch https://github.com/jdx/hk/releases/download/v$target/hk@$target.zip -
## verify the target release actually ships that asset before rewriting anything.
echo "Verifying release v$target (asset hk@$target.zip)"
meta=$(
  curl -fsSL --max-time 30 "$api/tags/v$target"
) || {
  echo "ERROR: could not query GitHub for release v$target" >&2
  exit 1
}
[ "$(jq -r .draft <<<"$meta")" = "false" ] || {
  echo "ERROR: v$target is a draft release" >&2
  exit 1
}
[ "$(jq -r .prerelease <<<"$meta")" = "false" ] || {
  echo "ERROR: v$target is a prerelease" >&2
  exit 1
}
if ! jq -e --arg asset "hk@$target.zip" 'any(.assets[]; .name == $asset)' <<<"$meta" >/dev/null; then
  echo "ERROR: release v$target does not ship the pkl package asset hk@$target.zip (the hk.pkl import would 404)" >&2
  exit 1
fi

if [ "$dry_run" = true ]; then
  echo "DRY RUN - no files changed. Would apply:"
  echo "  hk.pkl:    releases/download/v$old/hk@$old#  ->  releases/download/v$target/hk@$target#"
  echo "  mise.toml: $pin_line  ->  hk = { version = \"$target\", workflow = \"release.yml\" }"
  echo "  mise.lock: refreshed via 'mise lock'"
  exit 0
fi

echo "Rewriting hk pin: $old -> $target"
sed -i "s|releases/download/v$old/hk@$old#|releases/download/v$target/hk@$target#|g" hk.pkl
sed -i "s|^hk = { version = \"$old\", workflow = \"release.yml\" }\$|hk = { version = \"$target\", workflow = \"release.yml\" }|" mise.toml

## Post-conditions: both package lines moved, nothing stale left behind.
if [ "$(rg -F -c "hk@$target#" hk.pkl || true)" != "2" ]; then
  echo "ERROR: hk.pkl does not pin the package exactly twice after the rewrite - inspect manually" >&2
  exit 1
fi
if rg -F -q "hk@$old#" hk.pkl; then
  echo "ERROR: hk.pkl still references the old package after the rewrite - inspect manually" >&2
  exit 1
fi

echo "Refreshing mise.lock"
mise lock
if ! rg -F -q "releases/download/v$target/hk-" mise.lock; then
  echo "ERROR: mise.lock was not updated to v$target - inspect manually" >&2
  exit 1
fi

## Prove the pair works: the new binary plus the now-matching pin load the
## config via hk's embedded package (no network fetch needed at this point).
echo "Verifying config with the new binary"
installed=$(mise exec "hk@$target" -- hk --version)
if [ "$installed" != "hk $target" ]; then
  echo "ERROR: installed hk reports '$installed' (expected 'hk $target')" >&2
  exit 1
fi
mise exec "hk@$target" -- hk validate

echo
echo "hk bumped $old -> $target (hk.pkl package imports, mise.toml [tools] pin, mise.lock)"
echo "Next: review with 'git diff', run 'mise run check', then commit, e.g.:"
echo "  chore: bump hk to $target"
