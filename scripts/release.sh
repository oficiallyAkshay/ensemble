#!/bin/bash
# Builds a distributable DMG: build/Ensemble-<version>.dmg (+ .sha256). Safe to run repeatedly.
#
# Environment (all optional):
#   ENSEMBLE_SIGN_IDENTITY     "Developer ID Application: Name (TEAMID)" for a distribution build; default is the local identity
#                            (see scripts/bundle.sh). A local build gives a DMG for testing only: Gatekeeper blocks it elsewhere.
#   ENSEMBLE_NOTARY_PROFILE    notarytool keychain profile name (xcrun notarytool store-credentials). Enables notarize + staple.
#   ENSEMBLE_NOTARY_KEY_PATH   alternative for CI: App Store Connect API key (.p8), with ENSEMBLE_NOTARY_KEY_ID and (team keys)
#                            ENSEMBLE_NOTARY_ISSUER.
#   ENSEMBLE_VERSION           marketing version (CFBundleShortVersionString); default: the one in Info.plist.
#   ENSEMBLE_BUILD             build number (CFBundleVersion, what Sparkle compares); default: git commit count.
#   ENSEMBLE_DRY_RUN=1         (or --dry-run) print the notarytool/stapler commands instead of running them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LOG="/tmp/ensemble-release.log"
if [ -z "${ENSEMBLE_RELEASE_LOGGING:-}" ]; then
  export ENSEMBLE_RELEASE_LOGGING=1
  exec > >(tee "$LOG") 2>&1
fi

DRY_RUN="${ENSEMBLE_DRY_RUN:-0}"
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "usage: scripts/release.sh [--dry-run]" >&2; exit 2 ;;
  esac
done

log() { echo "[$(date -u +%FT%TZ)] $*"; }
die() { log "error: $*" >&2; exit 1; }
# Runs a command that talks to Apple's notary service, or only prints it in a dry run.
apple() { if [ "$DRY_RUN" = "1" ]; then log "DRY-RUN: $*"; else "$@"; fi; }

IDENTITY_NAME="${ENSEMBLE_SIGN_IDENTITY:-Ensemble Local Signing}"
case "$IDENTITY_NAME" in
  "Developer ID Application"*) DISTRIBUTION=1 ;;
  *) DISTRIBUTION=0 ;;
esac

NOTARY_ARGS=()
if [ -n "${ENSEMBLE_NOTARY_PROFILE:-}" ]; then
  NOTARY_ARGS=(--keychain-profile "$ENSEMBLE_NOTARY_PROFILE")
elif [ -n "${ENSEMBLE_NOTARY_KEY_PATH:-}" ]; then
  [ -n "${ENSEMBLE_NOTARY_KEY_ID:-}" ] || die "ENSEMBLE_NOTARY_KEY_PATH needs ENSEMBLE_NOTARY_KEY_ID"
  NOTARY_ARGS=(--key "$ENSEMBLE_NOTARY_KEY_PATH" --key-id "$ENSEMBLE_NOTARY_KEY_ID")
  [ -z "${ENSEMBLE_NOTARY_ISSUER:-}" ] || NOTARY_ARGS+=(--issuer "$ENSEMBLE_NOTARY_ISSUER")
fi
NOTARIZE=0
if [ "${#NOTARY_ARGS[@]}" -gt 0 ]; then
  [ "$DISTRIBUTION" = "1" ] || die "notarization needs a Developer ID identity; set ENSEMBLE_SIGN_IDENTITY=\"Developer ID Application: ...\""
  NOTARIZE=1
fi

VERSION="${ENSEMBLE_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/Ensemble/Info.plist)}"
BUILD="${ENSEMBLE_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
export ENSEMBLE_VERSION="$VERSION" ENSEMBLE_BUILD="$BUILD"

APP="build/Ensemble.app"
DMG="build/Ensemble-$VERSION.dmg"
STAGE="build/dmg-stage"
VOLNAME="Ensemble $VERSION"

log "release $VERSION (build $BUILD), signing: $IDENTITY_NAME, notarize: $([ $NOTARIZE = 1 ] && echo yes || echo no), dry run: $DRY_RUN"

log "step 1/5: build, assemble and sign the app (scripts/bundle.sh)"
scripts/bundle.sh

AUTHORITY=""
if [ "$DISTRIBUTION" = "1" ]; then
  AUTHORITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application.*\)$/\1/p' | head -1)"
  [ -n "$AUTHORITY" ] || die "the app is not signed with a Developer ID Application certificate"
fi

notarize() {
  local file="$1" result
  result="/tmp/ensemble-notary-$(basename "$file").json"
  log "notarizing $file (Apple's service usually takes 2 to 15 minutes)"
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY-RUN: xcrun notarytool submit $file ${NOTARY_ARGS[*]} --wait --output-format json"
    return 0
  fi
  xcrun notarytool submit "$file" "${NOTARY_ARGS[@]}" --wait --output-format json > "$result" || { cat "$result" >&2; die "notarytool submit failed"; }
  local status id
  status="$(plutil -extract status raw -o - "$result")"
  id="$(plutil -extract id raw -o - "$result")"
  if [ "$status" != "Accepted" ]; then
    xcrun notarytool log "$id" "${NOTARY_ARGS[@]}" >&2 || true
    die "notarization of $file ended with status \"$status\" (submission $id)"
  fi
  log "notarization accepted (submission $id)"
}

if [ "$NOTARIZE" = "1" ]; then
  log "step 2/5: notarize and staple the app"
  ZIP="build/Ensemble-notarize.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  rm -f "$ZIP"
  apple xcrun stapler staple "$APP"
  apple xcrun stapler validate "$APP"
else
  log "step 2/5: notarization skipped. Set ENSEMBLE_NOTARY_PROFILE (and sign with a Developer ID identity) to notarize."
fi

log "step 3/5: create $DMG"
rm -rf "$STAGE" "$DMG"
# The installer window (background, icon positions, no toolbar) is laid out by dmgbuild from scripts/dmg-settings.py,
# run through uv so nothing is installed globally. Pinned: bump deliberately.
command -v uvx >/dev/null || die "uvx is missing (brew install uv); it runs dmgbuild for the installer window"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Ensemble.app"
uvx --from "dmgbuild==1.6.7" dmgbuild -s scripts/dmg-settings.py -D app="$STAGE/Ensemble.app" "$VOLNAME" "$DMG"
rm -rf "$STAGE"

if [ "$DISTRIBUTION" = "1" ]; then
  log "step 4/5: sign the DMG"
  codesign --force --sign "$AUTHORITY" --timestamp "$DMG"
  if [ "$NOTARIZE" = "1" ]; then
    notarize "$DMG"
    apple xcrun stapler staple "$DMG"
    apple xcrun stapler validate "$DMG"
  fi
else
  log "step 4/5: DMG signing skipped (local identity: this DMG is for testing on this Mac only)"
fi

log "step 5/5: checksum"
(cd build && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

GATEKEEPER="not checked"
if [ "$NOTARIZE" = "1" ] && [ "$DRY_RUN" != "1" ]; then
  GATEKEEPER="$(spctl -a -t exec -vv "$APP" 2>&1 | tr '\n' ' ')"
elif [ "$DISTRIBUTION" = "0" ]; then
  GATEKEEPER="would be rejected (local identity)"
fi

SIZE_BYTES="$(stat -f %z "$DMG")"
log "summary"
cat <<SUMMARY
  version:     $VERSION (build $BUILD)
  signing:     $([ "$DISTRIBUTION" = "1" ] && echo "$AUTHORITY" || echo "local identity \"$IDENTITY_NAME\" (not for distribution)")
  notarized:   $([ $NOTARIZE = 1 ] && { [ "$DRY_RUN" = "1" ] && echo "dry run, not submitted" || echo "yes, stapled"; } || echo "no")
  gatekeeper:  $GATEKEEPER
  dmg:         $ROOT/$DMG
  size:        $SIZE_BYTES bytes ($(du -h "$DMG" | awk '{print $1}'))
  sha256:      $(cut -d' ' -f1 "$DMG.sha256")
  log:         $LOG
SUMMARY
