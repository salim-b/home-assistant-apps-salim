#!/usr/bin/env bash
#MISE description="Lint scripts, workflows, Dockerfiles, YAML and Markdown files"
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
  # -x: follow `source` lines - tasks sharing .mise/tasks/lib/ helpers would
  # otherwise fail with SC1091 (not following)
  shellcheck -x "$f" || fails=$((fails + 1))
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

echo "== panache (markdown formatting + semantic lint) =="
## Panache owns markdown autoformatting (see panache.toml): `format --check`
## gates the formatted state (nonzero + diff when a file needs formatting).
## `lint` checks semantic correctness (references, heading hierarchy, ...).
## Both walk directories recursively respecting .gitignore and the config's
## extend-exclude (AI_POLICY.md); the default exclude base skips common
## build/cache dirs and **/LICENSE.md. Like rumdl's walk, untracked
## non-ignored .md files are covered locally - a deliberate fail-fast.
## Panache's cache lives outside the repo (~/.cache/panache/).
panache format --check . || fails=$((fails + 1))
panache lint . || fails=$((fails + 1))

echo "== rumdl (markdown files) =="
## Idiomatic `rumdl check .` (documented default): a gitignore-respecting
## walk with the config's exclude patterns applied (AI_POLICY.md). In CI's
## clean checkout this covers exactly the tracked .md files; locally,
## untracked non-ignored scratch .md files are linted as well (verified -
## a deliberate fail-fast so a to-be-committed file can't slip through).
## rumdl's cache dir (.rumdl_cache/) self-ignores via its own .gitignore.
rumdl check . || fails=$((fails + 1))

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
