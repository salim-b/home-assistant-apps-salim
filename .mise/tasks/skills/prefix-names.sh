#!/usr/bin/env bash
#MISE description="Prefix vendored agent skills' frontmatter name: fields with `entire-` (post-sync step)"

set -euo pipefail

# Post-sync step for the vendir-vendored skills (root KNOWLEDGE.md §"Vendored agent skills"): vendir writes
# upstream-verbatim copies whose frontmatter `name:` fields are unprefixed, this task rewrites them to match the
# `entire-` directory-name prefix. The extract probe leaves files without a usable `name:` (or already prefixed)
# untouched, so re-runs are no-ops; yq's inplace rewrite re-renders multi-line frontmatter scalars (sanctioned
# deviation, see the upstream-verbatim policy in root KNOWLEDGE.md).
shopt -s nullglob
root="${MISE_PROJECT_ROOT:-.}"
count=0
for skill_md in "$root"/.agents/skills/entire-*/SKILL.md; do
  rel=${skill_md#"$root"/}
  name=$(yq --front-matter=extract '.name // ""' "$skill_md")
  case $name in "" | entire-*) continue ;; esac
  yq --front-matter=process --inplace '.name = "entire-" + .name' "$skill_md"
  printf '%s: name: %s -> name: entire-%s\n' "$rel" "$name" "$name"
  count=$((count + 1))
done
printf '%s file(s) rewritten\n' "$count"
