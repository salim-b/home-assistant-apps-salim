#!/usr/bin/env bash
#MISE description="Lint scripts, workflows, Dockerfiles, YAML and Markdown files"
set -euo pipefail
cd "$MISE_PROJECT_ROOT"

## Failure bookkeeping. Every failing check registers its label once (in
## first-failure order) plus - when known - the files it complained about,
## so the end-of-run summary can name WHICH check(s) failed on WHICH files.
## Without it, someone scanning the log tail sees only the last-printed
## section header above "LINT FAILED" and pins the failure on that step
## (e.g. a rumdl MD013 hit misread as an editorconfig final-newline
## failure). The -> FAILED: marker is printed under a failing check's own
## diagnostics, tying native tool output to its check unambiguously.
declare -a failed_checks=()
declare -A failed_seen=()   # label -> 1; dedupes fail_check calls
declare -A failed_files=()  # label -> newline-separated file paths

fail_check() {  # fail_check <label> [file...]
  local label=$1 file
  shift
  if [ -z "${failed_seen[$label]:-}" ]; then
    failed_seen[$label]=1
    failed_checks+=("$label")
    printf '%s\n' "-> FAILED: $label"
  fi
  for file in "$@"; do
    failed_files[$label]+="$file"$'\n'
  done
}

## Run one check whose tool finds its own file set (walks the tree itself).
## Captures the tool's combined output and re-prints it verbatim, so the
## log keeps the native diagnostics; on failure the label is registered and
## the complained-about files are parsed back out of that output. The
## extraction is best effort: the tools are version-pinned in mise.toml,
## and even if an output format ever drifts only the file list in the
## summary is lost - never the failure itself. The sed program must rewrite
## each diagnostic line carrying a path into just that path and drop every
## other line (s/.../\1/;t;d), i.e. stay in sync with the pinned tool's
## output format.
run_check() {  # run_check <label> <sed-program> <command...>
  local label=$1 sedprog=$2 out file
  shift 2
  if ! out=$("$@" 2>&1); then
    [ -n "$out" ] && printf '%s\n' "$out"
    fail_check "$label"
    # Strip the project prefix / ./ that some tools print, then dedupe.
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      failed_files[$label]+="$file"$'\n'
    done < <(printf '%s\n' "$out" | sed -E "$sedprog" |
      sed -E "s#^$PWD/##; s#^\./##" | sort -u)
    return 0
  fi
  [ -n "$out" ] && printf '%s\n' "$out"
  # The `[ -n ... ] &&` above must not become the function's status (an
  # empty success output would return 1 and trip set -e at the call site).
  return 0
}

# bash/sh scripts: shellcheck + bash -n
scripts=()
while IFS= read -r f; do
  first=$(head -1 "$f")
  case "$first" in
    *bash*|*"/sh") scripts+=("$f") ;;
  esac
done < <(git ls-files | while read -r f; do
  [[ "$f" == *.sh || "$f" == */cont-init.d/* || "$f" == */s6-overlay/scripts/* || "$f" == */s6-rc.d/*/run || "$f" == */s6-rc.d/*/finish || "$f" == .mise/tasks/* ]] && echo "$f"
done)

echo "== shellcheck / bash -n (${#scripts[@]} scripts) =="
[ ${#scripts[@]} -gt 0 ] || { echo "no scripts found" >&2; exit 1; }
for f in "${scripts[@]}"; do
  # -x: follow `source` lines - tasks sharing .mise/tasks/lib/ helpers would
  # otherwise fail with SC1091 (not following)
  shellcheck -x "$f" || fail_check "shellcheck (bash/sh scripts)" "$f"
  case "$(head -1 "$f")" in
    *bash*) bash -n "$f" || fail_check "bash -n (bash scripts)" "$f" ;;
  esac
done

echo "== actionlint (GitHub workflows) =="
run_check "actionlint (GitHub workflows)" \
  's/^([^:]+):[0-9]+:[0-9]+:.*/\1/;t;s/^::error file=([^,]+),line=.*/\1/;t;d' \
  actionlint -color

echo "== hadolint (Dockerfiles) =="
mapfile -t dockerfiles < <(git ls-files | grep -E '(^|/)Dockerfile$')
[ ${#dockerfiles[@]} -gt 0 ] || { echo "no Dockerfiles found" >&2; exit 1; }
for f in "${dockerfiles[@]}"; do
  hadolint "$f" || fail_check "hadolint (Dockerfiles)" "$f"
done

echo "== yamllint (yaml files) =="
mapfile -t yamlfiles < <(git ls-files | grep -E '\.ya?ml$')
[ ${#yamlfiles[@]} -gt 0 ] || { echo "no yaml files found" >&2; exit 1; }
# yamllint's standard format: offending files appear as unindented lines
# (issue lines are indented) - extract those.
run_check "yamllint (yaml files)" \
  's/^([^ ].*)$/\1/;t;d' \
  yamllint "${yamlfiles[@]}"

echo "== panache (markdown formatting + semantic lint) =="
## Panache owns markdown autoformatting (see panache.toml): `format --check`
## gates the formatted state (nonzero + diff when a file needs formatting).
## `lint` checks semantic correctness (references, heading hierarchy, ...).
## Both walk directories recursively respecting .gitignore and the config's
## extend-exclude (AI_POLICY.md); the default exclude base skips common
## build/cache dirs and **/LICENSE.md. Like rumdl's walk, untracked
## non-ignored .md files are covered locally - a deliberate fail-fast.
## Panache's cache lives outside the repo (~/.cache/panache/).
run_check "panache format (markdown formatting)" \
  's/^Diff in (.+):[0-9]+:$/\1/;t;d' \
  panache format --check .
run_check "panache lint (markdown semantics)" \
  's/^[[:space:]]*--> (.+):[0-9]+:[0-9]+$/\1/;t;d' \
  panache lint .

echo "== rumdl (markdown files) =="
## Idiomatic `rumdl check .` (documented default): a gitignore-respecting
## walk with the config's exclude patterns applied (AI_POLICY.md). In CI's
## clean checkout this covers exactly the tracked .md files; locally,
## untracked non-ignored scratch .md files are linted as well (verified -
## a deliberate fail-fast so a to-be-committed file can't slip through).
## rumdl's cache dir (.rumdl_cache/) self-ignores via its own .gitignore.
run_check "rumdl (markdown files)" \
  's/^([^ ]+):[0-9]+:[0-9]+:.*/\1/;t;d' \
  rumdl check .

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
  fail_check "editorconfig: final newlines (text files)" "${no_final_newline[@]}"
fi

if [ ${#failed_checks[@]} -gt 0 ]; then
  printf 'LINT FAILED: %d failing check(s):\n' "${#failed_checks[@]}" >&2
  for label in "${failed_checks[@]}"; do
    list=""
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      list+="${list:+, }$file"
    done <<<"${failed_files[$label]:-}"
    if [ -n "$list" ]; then
      printf '  - %s: %s\n' "$label" "$list" >&2
    else
      printf '  - %s\n' "$label" >&2
    fi
  done
  exit 1
fi
echo "lint OK"
