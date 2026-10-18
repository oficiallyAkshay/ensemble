#!/bin/bash
# Turns the current main into a release that installed copies pick up through Check for Updates:
#   scripts/ship-release.sh 0.2.0
# Tags main, builds and signs the DMG with this Mac's identity (scripts/release.sh), publishes the GitHub Release,
# adds the DMG to the appcast (scripts/appcast.sh, signed with the update key in this Mac's login keychain) and
# pushes the appcast to the gh-pages branch that GitHub Pages serves. Run it right after a merge to main.
# Everything that can refuse (the DMG, the signed appcast) happens before the tag and the release exist, so a refusal
# leaves nothing public to take back.
# Log: build/ship.log
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${1:?usage: scripts/ship-release.sh <version, e.g. 0.2.0>}"
TAG="v$VERSION"
mkdir -p build
LOG=build/ship.log
log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }

# A release signed with an expired local certificate breaks updates, and a new certificate resets every user's Camera
# and Accessibility grants, so the date must never be a surprise (docs/RELEASING.md, "Signing certificate expiry").
# The date is read from the certificate itself, so it cannot go stale. Developer ID certificates are Apple's and not
# checked. ENSEMBLE_SIGN_CERT_PEM points the check at a certificate file instead of the keychain, to try it out.
case "${ENSEMBLE_SIGN_IDENTITY:-}" in
  "Developer ID Application"*) ;;
  *)
    if [ -n "${ENSEMBLE_SIGN_CERT_PEM:-}" ]; then
      CERT="$(cat "$ENSEMBLE_SIGN_CERT_PEM" 2>/dev/null || true)"
    elif [ -n "${ENSEMBLE_SIGN_IDENTITY:-}" ]; then
      CERT="$(security find-certificate -c "$ENSEMBLE_SIGN_IDENTITY" -p 2>/dev/null || true)"
    else
      # The same order scripts/bundle.sh signs with: the default identity, then the app's earlier working name.
      CERT="$(security find-certificate -c "Ensemble Local Signing" -p 2>/dev/null \
        || security find-certificate -c "Clutch Local Signing" -p 2>/dev/null || true)"
    fi
    CERT_END="$(openssl x509 -noout -enddate <<<"$CERT" 2>/dev/null | cut -d= -f2 || true)"
    if [ -z "$CERT_END" ]; then
      log "warning: could not read the signing certificate's expiry date; see docs/RELEASING.md, \"Signing certificate expiry\""
    elif ! openssl x509 -noout -checkend 0 <<<"$CERT" >/dev/null; then
      log "error: the signing certificate expired on $CERT_END; releases signed with it break updates (docs/RELEASING.md, \"Signing certificate expiry\")"
      exit 1
    elif ! openssl x509 -noout -checkend 5184000 <<<"$CERT" >/dev/null; then
      log "warning: the signing certificate expires on $CERT_END, within 60 days; move to Developer ID signing before then (docs/RELEASING.md, \"Signing certificate expiry\")"
    fi
    ;;
esac

# Only a clean main that matches GitHub ships: the release must be exactly what was merged.
# Explicit refspecs: a clone made for one branch (the production Mac's job service clone) has no fetch refspec, so a
# plain fetch would leave origin/gh-pages and the remote tags missing.
git fetch --quiet --tags origin +refs/heads/main:refs/remotes/origin/main +refs/heads/gh-pages:refs/remotes/origin/gh-pages
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { log "error: HEAD is not origin/main; check out main and pull first"; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { log "error: uncommitted changes; this must be a clean main"; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { log "error: $TAG already exists; versions are never reused"; exit 1; }

REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
PREV="$(git describe --tags --abbrev=0 2>/dev/null || true)"
log "shipping $TAG from $(git rev-parse --short HEAD) of $REPO (previous: ${PREV:-none})"

ENSEMBLE_VERSION="$VERSION" scripts/release.sh 2>&1 | tee -a "$LOG"
DMG="build/Ensemble-$VERSION.dmg"
[ -f "$DMG" ] || { log "error: $DMG was not built"; exit 1; }

# scripts/appcast.sh embeds the notes only from a file ending in .md, .html or .txt, and macOS mktemp adds no suffix.
NOTES_DIR="$(mktemp -d)"
NOTES="$NOTES_DIR/notes.md"
PAGES="$(mktemp -d)"
# The gh-pages checkout is a git worktree: remove it on every exit, or a failed run leaves it registered.
cleanup() { rm -rf "$NOTES_DIR"; git worktree remove --force "$PAGES" 2>/dev/null || true; rm -rf "$PAGES"; }
trap cleanup EXIT
# First parent only: a pull request's merge of main into its branch would add its conflict list as a line.
# A merge commit contributes its body (the pull request title); a squash-merged pull request is an ordinary commit and contributes its subject.
{ echo "Changes since ${PREV:-the first commit}:"; echo; { git log --first-parent --merges --format='- %b' "${PREV:+$PREV..}HEAD"; git log --first-parent --no-merges --format='- %s' "${PREV:+$PREV..}HEAD"; } | grep -v '^- $' || true; } > "$NOTES"

# The appcast lives on gh-pages; extend the published one so older items stay listed. It is built and checked now
# (scripts/appcast.sh refuses an unsigned item), before anything public exists; the download address is known
# from the tag alone.
git worktree add --quiet "$PAGES" origin/gh-pages --detach
rm -rf build/appcast
mkdir -p build/appcast
[ ! -f "$PAGES/appcast.xml" ] || cp "$PAGES/appcast.xml" build/appcast/appcast.xml
ENSEMBLE_DOWNLOAD_PREFIX="https://github.com/$REPO/releases/download/$TAG/" ENSEMBLE_RELEASE_NOTES="$NOTES" scripts/appcast.sh "$DMG" build/appcast 2>&1 | tee -a "$LOG"
[ -s build/appcast/appcast.xml ] || { log "error: no appcast was produced; nothing was tagged or published"; exit 1; }
PAGES_SHA="$(gh api "repos/$REPO/contents/appcast.xml?ref=gh-pages" --jq .sha 2>/dev/null || true)"

# The tag and the appcast go through GitHub's API, not git push: the production Mac's job service lets a job push
# only its own branch, and a release touches neither main nor any branch's history except gh-pages' appcast file.
# Ensemble.dmg, the same file under a fixed name, is what the website's Download buttons fetch directly:
# https://github.com/<repo>/releases/latest/download/Ensemble.dmg always resolves to the newest release.
cp "$DMG" build/Ensemble.dmg
gh release create "$TAG" "$DMG" "$DMG.sha256" build/Ensemble.dmg --target "$(git rev-parse HEAD)" \
  --title "Ensemble $VERSION" --notes-file "$NOTES" | tee -a "$LOG"

gh api -X PUT "repos/$REPO/contents/appcast.xml" -f branch=gh-pages -f message="Appcast: Ensemble $VERSION" \
  -f content="$(base64 < build/appcast/appcast.xml | tr -d '\n')" ${PAGES_SHA:+-f sha="$PAGES_SHA"} --jq .commit.sha | tee -a "$LOG"
log "done: $TAG released; installed copies see it within their next update check"
