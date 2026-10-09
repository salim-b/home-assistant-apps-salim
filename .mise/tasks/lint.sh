#!/usr/bin/env bash
#MISE description="Lint all scripts, workflows, Dockerfiles and YAML files"
set -euo pipefail
cd "$MISE_PROJECT_ROOT"

fails=0
scripts=()
# bash/sh scripts: shellcheck + bash -n
while IFS= read -r f; do
  first=$(head -1 "$f")
  case "$first" in
    *bash*|*"/sh") scripts+=("$f") ;;
  esac
done < <(git ls-files | while read -r f; do
  [[ "$f" == *.sh || "$f" == */cont-init.d/* || "$f" == */s6-overlay/scripts/* || "$f" == */s6-rc.d/*/run || "$f" == */s6-rc.d/*/finish || "$f" == .mise/tasks/* ]] && echo "$f"
done)

echo "== shellcheck / bash -n (${#scripts[@]} scripts) =="
[ ${#scripts[@]} -gt 0 ] || { echo "no scripts found"; exit 1; }
for f in "${scripts[@]}"; do
  shellcheck "$f" || fails=$((fails + 1))
  case "$(head -1 "$f")" in *bash*) bash -n "$f" || fails=$((fails + 1));; esac
done

echo "== actionlint (GitHub workflows) =="
actionlint -color || fails=$((fails + 1))

echo "== hadolint (Dockerfiles) =="
while IFS= read -r dockerfile; do
  hadolint "$dockerfile" || fails=$((fails + 1))
done < <(git ls-files | grep -E '(^|/)Dockerfile$')

echo "== yamllint (yaml files) =="
mapfile -t yamlfiles < <(git ls-files | grep -E '\.ya?ml$')
yamllint "${yamlfiles[@]}" || fails=$((fails + 1))

if [ "$fails" -gt 0 ]; then
  echo "LINT FAILED: $fails problem(s)" >&2
  exit 1
fi
echo "lint OK"
