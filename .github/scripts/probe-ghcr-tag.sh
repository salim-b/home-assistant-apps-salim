#!/usr/bin/env bash
# Probe one registry tag's existence and classify the outcome. Consumers of the image-name
# contract (repository README §"CI"): the publish-reconcile workflow's tag check and the
# version-guard workflow's unpublished-base-version exception. Probes via the preinstalled
# `docker buildx imagetools inspect` (talks to the registry API directly – no daemon, no login
# for the repo's public GHCR packages).
#
# Classification follows project-copacetic's ensure-tag-absent.sh: success -> ok, not-found-class
# errors -> missing, anything else unreachable (retried with exponential backoff; diagnostics to
# stderr). Each attempt is time-bounded (SIGTERM then SIGKILL – buildx traps SIGTERM and would
# outlive plain `timeout`); "404 not found" also matches the error-text variants of other buildx
# versions.
#
# Usage: probe-ghcr-tag.sh <registry/ref:tag> [retries]
# Prints exactly one verdict on stdout: ok | missing | unreachable (exit 0 in all three cases -
# the verdict is the result; only usage errors exit non-zero).
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: probe-ghcr-tag.sh <registry/ref:tag> [retries]" >&2
  exit 2
fi
ref="$1"
retries="${2:-3}"

attempt=0
while :; do
  if out=$(timeout -k 10 60 docker buildx imagetools inspect "$ref" 2>&1); then
    echo ok
    exit 0
  fi
  if grep -Eiq '(manifest unknown|name unknown|no such manifest|: not found[[:space:]]*$|404 not found)' <<<"$out"; then
    echo missing
    exit 0
  fi
  if [ "$attempt" -ge "$retries" ]; then
    echo unreachable
    printf 'probe %s: unclassified failure after %d attempts, last error:\n%s\n' "$ref" "$((attempt + 1))" "$out" >&2
    exit 0
  fi
  backoff=$((5 * 2 ** attempt)) # 5, 10, 20 ... seconds
  sleep "$backoff"
  attempt=$((attempt + 1))
done
