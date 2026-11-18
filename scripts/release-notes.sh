#!/bin/bash
# Prints the release notes for HEAD, newest change first, one line per change since the previous tag:
#   scripts/release-notes.sh [previous tag]
# A change that added a note file under docs/changes (README.md aside) contributes one line per added file, the file's text.
# Any other change contributes what the notes held before note files existed: a merge commit its body (the pull request
# title), an ordinary or squash-merged commit its subject. So changes merged before the first note file are still listed.
# First parent only: a pull request's merge of main into its branch would add its conflict list as a line.
# Runs in the repository of the current directory; scripts/ship-release.sh calls it.
set -euo pipefail

PREV="${1:-}"
cd "$(git rev-parse --show-toplevel)"
EMPTY_TREE="$(git hash-object -t tree /dev/null)"

echo "Changes since ${PREV:-the first commit}:"
echo
for c in $(git rev-list --first-parent "${PREV:+$PREV..}HEAD"); do
  # Against the first parent, so a merge commit shows what it brought in; the root commit has none.
  base="$(git rev-parse -q --verify "$c^" || echo "$EMPTY_TREE")"
  added="$(git diff --diff-filter=A --name-only "$base" "$c" -- docs/changes ':(exclude)docs/changes/README.md')"
  if [ -n "$added" ]; then
    while IFS= read -r f; do
      text="$(git show "$c:$f" | grep -v '^[[:space:]]*$' | tr '\n' ' ' | sed 's/ *$//' || true)"
      [ -z "$text" ] || printf -- '- %s\n' "$text"
    done <<< "$added"
  elif [ "$(git rev-list --count --merges "$c^!")" -gt 0 ]; then
    git log -1 --format='- %b' "$c" | grep -v -e '^- $' -e '^$' || true
  else
    git log -1 --format='- %s' "$c" | grep -v '^- $' || true
  fi
done
