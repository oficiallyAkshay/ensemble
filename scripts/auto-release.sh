#!/bin/bash
# Cuts a release by itself after a merge to main changes app logic. Run every 5 minutes by the dev.ensemble.releaser
# launchd agent that scripts/install-auto-release.sh writes; no Claude session or routine is involved.
#   scripts/auto-release.sh --dry-run    print the decision, version, commits and notes; build, sign, tag and publish nothing
# Each run: fetch origin; if nothing under Sources/, Package.swift or Package.resolved changed since the newest v* tag,
# stop quietly. Otherwise wait for the `ci` run on main's newest commit to succeed, work out the next patch version,
# make a throwaway worktree of exactly that commit and run scripts/ship-release.sh there (it signs with the login keychain:
# the exception approved in AGENTS.md). The worktree is removed on every exit path.
# Log: ~/Library/Logs/Ensemble/releaser.log (UTC, one line per decision; a repeated decision is logged once).
# Off switch: scripts/install-auto-release.sh --uninstall   (or: launchctl bootout "gui/$(id -u)/dev.ensemble.releaser")
# The agent pipes a copy of this file from origin/main into bash, so a stale checkout still runs the current script.
# Settings, all optional: ENSEMBLE_RELEASER_REPO (the checkout to work from, default: the one holding this file),
# ENSEMBLE_RELEASER_GH_REPO (owner/name, default: from the checkout's origin), ENSEMBLE_RELEASER_LOG_DIR,
# ENSEMBLE_RELEASER_STATE_DIR, ENSEMBLE_RELEASER_CI_JSON (a file standing in for the `gh run list` answer),
# ENSEMBLE_RELEASER_NO_NOTIFY=1.
set -uo pipefail

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$PATH"

if [ -n "${ENSEMBLE_RELEASER_REPO:-}" ]; then ROOT="$ENSEMBLE_RELEASER_REPO"
else ROOT="$(cd "$(dirname "$0")/.." && pwd)"; fi
LOG_DIR="${ENSEMBLE_RELEASER_LOG_DIR:-$HOME/Library/Logs/Ensemble}"
STATE_DIR="${ENSEMBLE_RELEASER_STATE_DIR:-$HOME/Library/Application Support/Ensemble/releaser}"
LOG="$LOG_DIR/releaser.log"
SHIP_LOG="$LOG_DIR/releaser-ship.log"
LAST="$STATE_DIR/last-decision"
LOCK="$STATE_DIR/lock"
FEED="https://oficiallyakshay.github.io/ensemble/appcast.xml"
WT=""

mkdir -p "$LOG_DIR" "$STATE_DIR"

# Output of a dry run goes to the screen only; a real run only to the log.
say() {
  if [ "$DRY" = 1 ]; then echo "$*"; else echo "[$(date -u +%FT%TZ)] $*" >> "$LOG"; fi
}
notify() {
  [ "$DRY" = 1 ] || [ -n "${ENSEMBLE_RELEASER_NO_NOTIFY:-}" ] && return 0
  local msg="${1//\"/}"; msg="${msg//\\/}"
  osascript -e "display notification \"$msg\" with title \"Ensemble releaser\"" >/dev/null 2>&1 || true
}
# A decision that repeats every 5 minutes (nothing due, CI pending, CI red) is logged when it first appears only.
decide() { # key message
  if [ "$DRY" = 1 ]; then say "$2"; return 0; fi
  [ "$(cat "$LAST" 2>/dev/null || true)" = "$1" ] && return 0
  printf '%s' "$1" > "$LAST"; say "$2"
}
# A refusal is logged and notified once per distinct cause.
refuse() { # key message
  local changed=1
  [ "$(cat "$LAST" 2>/dev/null || true)" = "$1" ] && changed=0
  decide "$1" "refused: $2"
  [ "$changed" = 1 ] && notify "Release refused: $2"
  return 0
}

cleanup() {
  if [ -n "$WT" ]; then
    git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || true
    rm -rf "$WT"; git -C "$ROOT" worktree prune >/dev/null 2>&1 || true
  fi
  [ "$DRY" = 1 ] || rm -rf "$LOCK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# One run at a time: a build outlasts the 5-minute interval.
if [ "$DRY" = 0 ] && ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
    say "stale lock removed"; rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi

[ -d "$ROOT/.git" ] || [ -f "$ROOT/.git" ] || { say "error: $ROOT is not a git checkout"; exit 1; }
cd "$ROOT" || exit 1

# Explicit refspecs: a clone made for one branch has no fetch refspec for the others, as in ship-release.sh.
if ! git fetch --quiet --tags origin +refs/heads/main:refs/remotes/origin/main +refs/heads/gh-pages:refs/remotes/origin/gh-pages 2>/dev/null; then
  say "fetch failed; retrying next run"; exit 0
fi
MAIN_SHA="$(git rev-parse origin/main)"
TAG="$(git tag --list 'v[0-9]*' --sort=-v:refname | head -1)"
[ -n "$TAG" ] || { refuse "no-tag" "no v* tag exists; the first release is cut by hand"; exit 0; }
if ! git merge-base --is-ancestor "$TAG" origin/main 2>/dev/null; then
  refuse "tag-not-ancestor-$TAG" "$TAG is not an ancestor of origin/main; not guessing which commits are unreleased"; exit 0
fi

# App logic: Sources/, Package.swift, Package.resolved (docs/RELEASING.md). Anything else waits for the next release.
CHANGED="$(git diff --name-only "$TAG" origin/main -- Sources Package.swift Package.resolved)"
if [ -z "$CHANGED" ]; then
  decide "idle-$TAG-$MAIN_SHA" "nothing due: no app-logic change between $TAG and ${MAIN_SHA:0:7}"; exit 0
fi

if [ -z "${ENSEMBLE_RELEASER_GH_REPO:-}" ]; then ENSEMBLE_RELEASER_GH_REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"; fi
GH_REPO="${ENSEMBLE_RELEASER_GH_REPO:-}"
[ -n "$GH_REPO" ] || { say "could not tell which GitHub repository this is; retrying next run"; exit 0; }

# Checks: the newest `ci` run on main's newest commit must have finished green.
if [ -n "${ENSEMBLE_RELEASER_CI_JSON:-}" ]; then RUNS="$(cat "$ENSEMBLE_RELEASER_CI_JSON")"
else RUNS="$(gh run list --repo "$GH_REPO" --branch main --workflow ci --limit 30 --json headSha,status,conclusion 2>/dev/null || true)"; fi
CI_STATE="$(printf '%s' "${RUNS:-[]}" | jq -r --arg sha "$MAIN_SHA" '[.[] | select(.headSha == $sha)][0] | if . == null then "none" elif .status != "completed" then "pending" else (.conclusion // "unknown") end' 2>/dev/null || echo "unknown")"
CI_OK=0
case "$CI_STATE" in
  success) CI_OK=1 ;;
  none|pending|unknown|"") decide "ci-pending-$MAIN_SHA" "waiting: ci on ${MAIN_SHA:0:7} is not finished ($CI_STATE); retrying next run" ;;
  *) decide "ci-failed-$MAIN_SHA" "not releasing: ci on ${MAIN_SHA:0:7} finished as $CI_STATE" ;;
esac
[ "$CI_OK" = 1 ] || [ "$DRY" = 1 ] || exit 0

# Next patch version; never reuse one, locally or on GitHub.
CUR="${TAG#v}"
case "$CUR" in [0-9]*.[0-9]*.[0-9]*) ;; *) refuse "bad-tag-$TAG" "$TAG is not major.minor.patch"; exit 0 ;; esac
VERSION="${CUR%.*}.$(( ${CUR##*.} + 1 ))"
NEW_TAG="v$VERSION"
if git rev-parse -q --verify "refs/tags/$NEW_TAG" >/dev/null || [ -n "$(git ls-remote --tags origin "refs/tags/$NEW_TAG" 2>/dev/null)" ] \
   || gh release view "$NEW_TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
  refuse "exists-$NEW_TAG" "$NEW_TAG already exists (tag or GitHub release); versions are never reused"; CI_OK=0
  [ "$DRY" = 1 ] || exit 0
fi

# Release notes text for the update window (only where the repository has the tool for it).
SUBJECTS="$(git log --first-parent --no-merges --format='%s' "$TAG..origin/main" | sed -E 's/ \(#[0-9]+\)$//' | head -5)"
whats_new_text() {
  local icons=(sparkles wand.and.stars hand.raised gearshape bolt) n=0 subject heading
  while IFS= read -r subject; do
    [ -n "$subject" ] || continue
    subject="${subject//|/-}"
    heading="$(printf '%s' "$subject" | awk '{ for (i = 1; i <= NF && i <= 6; i++) printf "%s%s", (i > 1 ? " " : ""), $i }')"
    echo "${icons[$(( n % ${#icons[@]} ))]} | $heading | $subject"
    n=$(( n + 1 ))
  done <<< "$SUBJECTS"
  while [ "$n" -lt 3 ]; do
    echo "checkmark.circle | Fixes and polish | Smaller fixes and behind-the-scenes improvements."
    n=$(( n + 1 ))
  done
}
HAS_WHATS_NEW=0
git cat-file -e origin/main:scripts/whats-new.sh 2>/dev/null && ! git cat-file -e "origin/main:docs/whats-new/$VERSION.txt" 2>/dev/null && HAS_WHATS_NEW=1

if [ "$DRY" = 1 ]; then
  echo "dry run: nothing is built, signed, tagged or published"
  echo "latest tag:     $TAG"
  echo "origin/main:    ${MAIN_SHA:0:7}"
  echo "app-logic files changed since $TAG: $(printf '%s\n' "$CHANGED" | wc -l | tr -d ' ')"
  echo "ci on ${MAIN_SHA:0:7}: $CI_STATE"
  echo "next version:   $VERSION (tag $NEW_TAG, repository $GH_REPO)"
  echo "commits since $TAG:"; git log --first-parent --format='  %h %s' "$TAG..origin/main"
  if [ "$HAS_WHATS_NEW" = 1 ]; then echo "docs/whats-new/$VERSION.txt would be written:"; whats_new_text | sed 's/^/  /'
  else echo "no docs/whats-new file would be written (scripts/whats-new.sh absent on main, or the file is already committed)"; fi
  if [ "$CI_OK" = 1 ]; then echo "result: would release $NEW_TAG now"; else echo "result: would not release yet (ci: $CI_STATE)"; fi
  exit 0
fi

say "releasing $NEW_TAG from ${MAIN_SHA:0:7} (previous $TAG, ci green)"
WT="$(mktemp -d "${TMPDIR:-/tmp}/ensemble-release.XXXXXX")"
if ! git worktree add --quiet --detach "$WT" "$MAIN_SHA" 2>>"$LOG"; then
  say "could not create the release worktree; retrying next run"; exit 0
fi
if [ "$HAS_WHATS_NEW" = 1 ]; then
  mkdir -p "$WT/docs/whats-new"
  whats_new_text > "$WT/docs/whats-new/$VERSION.txt"
  if ! (cd "$WT" && scripts/whats-new.sh check "docs/whats-new/$VERSION.txt") >>"$SHIP_LOG" 2>&1; then
    refuse "whats-new-$VERSION" "the generated notes for $NEW_TAG failed scripts/whats-new.sh check; see releaser-ship.log"; exit 0
  fi
  say "wrote docs/whats-new/$VERSION.txt (untracked)"
fi

echo "[$(date -u +%FT%TZ)] ship $NEW_TAG" >> "$SHIP_LOG"
if ! (cd "$WT" && scripts/ship-release.sh "$VERSION") >>"$SHIP_LOG" 2>&1; then
  refuse "ship-$NEW_TAG-${MAIN_SHA:0:7}" "scripts/ship-release.sh $VERSION failed ($(grep -E 'error' "$SHIP_LOG" | tail -1 | cut -c1-160)); see releaser-ship.log"
  exit 0
fi

# Prove it is public: the GitHub release, then the feed that installed copies read.
RELEASE_OK=0; FEED_OK=0
for _ in $(seq 1 12); do
  [ "$RELEASE_OK" = 1 ] || { gh release view "$NEW_TAG" --repo "$GH_REPO" >/dev/null 2>&1 && RELEASE_OK=1; }
  [ "$FEED_OK" = 1 ] || { curl -fsS --max-time 20 -H 'Cache-Control: no-cache' "$FEED" 2>/dev/null | grep -qF "releases/download/$NEW_TAG/" && FEED_OK=1; }
  [ "$RELEASE_OK" = 1 ] && [ "$FEED_OK" = 1 ] && break
  sleep 15
done
rm -f "$LAST"
if [ "$RELEASE_OK" = 1 ] && [ "$FEED_OK" = 1 ]; then
  say "released $NEW_TAG: GitHub release exists and the feed lists $VERSION"
  notify "Released Ensemble $VERSION"
else
  say "released $NEW_TAG but verification is incomplete: release=$RELEASE_OK feed=$FEED_OK"
  notify "Ensemble $VERSION shipped; check the feed (release=$RELEASE_OK feed=$FEED_OK)"
fi
exit 0
