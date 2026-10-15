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

echo "== rumdl (markdown files) =="
mapfile -t mdfiles < <(git ls-files | grep -E '\.md$')
rumdl check "${mdfiles[@]}" || fails=$((fails + 1))

## .editorconfig [**] insert_final_newline: no linter above covers it for
## non-YAML text files (yamllint's new-line-at-end-of-file only sees YAML) -
## enforce it repo-wide. Binary files are skipped (grep -I: "process a
## binary file as if it did not contain matching data"); empty files are
## skipped (a final-newline requirement cannot apply to them). Beware POSIX
## ERE bracket expressions: "[ \t]" does NOT mean space/tab (\t is literal
## backslash+t) - use [[:blank:]] classes if ever extending this.
echo "== editorconfig: final newlines (text files) =="
no_final_newline=()
while IFS= read -r -d '' f; do
  [ -s "$f" ] || continue
  LC_ALL=C grep -qI '^' "$f" 2>/dev/null || continue
  # $( ) strips trailing newlines: empty = the file's last byte is a newline
  if [ -n "$(tail -c1 "$f")" ]; then
    no_final_newline+=("$f")
  fi
done < <(git ls-files -z)
if [ ${#no_final_newline[@]} -gt 0 ]; then
  printf 'missing final newline (%s files):\n' "${#no_final_newline[@]}"
  printf '  %s\n' "${no_final_newline[@]}"
  fails=$((fails + 1))
fi

if [ "$fails" -gt 0 ]; then
  echo "LINT FAILED: $fails problem(s)" >&2
  exit 1
fi
echo "lint OK"
