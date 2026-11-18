#!/bin/bash
# Builds build/Ensemble.app from the SwiftPM release build. Safe to run repeatedly.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="build/Ensemble.app"
# The log sits under build/ (ignored by git, owned by this checkout), never under a fixed, guessable system temp name that another
# user could pre-create or link elsewhere. scripts/dev-install.sh reads it for its error excerpt.
mkdir -p build
LOG="build/bundle.log"

# The macOS 27 SDK makes SwiftUI's @State a macro whose compiler plugin ships with Xcode only, so with just the
# Command Line Tools every view fails ("plugin for module 'SwiftUIMacros' not found"). Build against the macOS 26 SDK
# there; the app still runs on macOS 27. An explicit SDKROOT is never overridden.
CLT_SDKS="/Library/Developer/CommandLineTools/SDKs"
if [ -z "${SDKROOT:-}" ] && [ "$(xcode-select -p 2>/dev/null)" = "/Library/Developer/CommandLineTools" ] && [ -d "$CLT_SDKS/MacOSX26.sdk" ]; then
  export SDKROOT="$CLT_SDKS/MacOSX26.sdk"
fi

# -Osize: the app's own code is not the CPU-heavy part (WebKit, Vision and the GPU are), so size wins over speed.
echo "[$(date -u +%FT%TZ)] swift build -c release -Xswiftc -Osize" | tee "$LOG"
swift build -c release -Xswiftc -Osize 2>&1 | tee -a "$LOG"
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "[$(date -u +%FT%TZ)] assembling $APP" | tee -a "$LOG"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Ensemble" "$APP/Contents/MacOS/Ensemble"
strip -x "$APP/Contents/MacOS/Ensemble"
cp Sources/Ensemble/Info.plist "$APP/Contents/Info.plist"

if [ -f Assets/AppIcon.icns ]; then
  cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  echo "warning: Assets/AppIcon.icns missing; run: swift scripts/make-icon.swift" | tee -a "$LOG"
fi

# The face tracker's web folder is copied here directly rather than as a SwiftPM resource bundle, whose generated
# accessor embeds the build machine's absolute path in the binary (Package.swift). EnsembleResources finds it.
WEB_SRC="Sources/Ensemble/Resources/web"
if [ -d "$WEB_SRC" ]; then
  cp -R "$WEB_SRC" "$APP/Contents/Resources/web"
  # Large web files are stored LZMA-packed (about 5 MB smaller); AssetSchemeHandler unpacks them on the fly.
  echo "[$(date -u +%FT%TZ)] packing web assets" | tee -a "$LOG"
  swift scripts/pack-web.swift "$APP/Contents/Resources/web" 2>&1 | tee -a "$LOG"
else
  echo "error: $WEB_SRC not found" | tee -a "$LOG"
  exit 1
fi

# Embed Sparkle (a SwiftPM binary framework: the build leaves it next to the binary, the app needs it in Contents/Frameworks;
# the linker already added the @executable_path/../Frameworks rpath, see Package.swift).
SPARKLE_SRC="$BIN_DIR/Sparkle.framework"
if [ ! -d "$SPARKLE_SRC" ]; then
  echo "error: $SPARKLE_SRC not found (run swift package resolve)" | tee -a "$LOG" >&2
  exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_SRC" "$APP/Contents/Frameworks/Sparkle.framework"
# Ensemble is not sandboxed, so Sparkle's XPC services are not used (https://sparkle-project.org/documentation/sandboxing/).
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
# The app is arm64 only: keep the arm64 slice of Sparkle's code, drop the Intel half, local symbols and the headers.
SPARKLE_B="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for macho in "$SPARKLE_B/Sparkle" "$SPARKLE_B/Autoupdate" "$SPARKLE_B/Updater.app/Contents/MacOS/Updater"; do
  lipo "$macho" -thin arm64 -output "$macho.thin"
  mv "$macho.thin" "$macho"
  strip -x "$macho"
done
rm -rf "$SPARKLE_B/Headers" "$SPARKLE_B/PrivateHeaders" "$SPARKLE_B/Modules" \
  "$APP/Contents/Frameworks/Sparkle.framework/Headers" "$APP/Contents/Frameworks/Sparkle.framework/PrivateHeaders" "$APP/Contents/Frameworks/Sparkle.framework/Modules"
# The app declares no language but English, so Sparkle's other translations are never shown beside it; Base holds its English.
for lproj in "$SPARKLE_B"/Resources/*.lproj; do
  case "$(basename "$lproj")" in Base.lproj | en.lproj) ;; *) rm -rf "$lproj" ;; esac
done

# Optional version stamping for releases (scripts/release.sh). Sparkle compares CFBundleVersion, so it must grow every release.
if [ -n "${ENSEMBLE_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ENSEMBLE_VERSION" "$APP/Contents/Info.plist"
fi
# A development build (scripts/dev-update.sh) follows main, not releases: without the update key its Sparkle stays off,
# so a published release never installs over it with a different signature and drops the Accessibility grant.
if [ -n "${ENSEMBLE_DEV_BUILD:-}" ]; then
  /usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$APP/Contents/Info.plist"
fi
if [ -n "${ENSEMBLE_BUILD:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $ENSEMBLE_BUILD" "$APP/Contents/Info.plist"
fi

# Signing uses one pinned identity so the designated requirement (what Camera and Accessibility grants are tied
# to) is the same on every build. Set ENSEMBLE_SIGN_IDENTITY to use another identity name; there is no ad-hoc
# fallback, because an ad-hoc signature is a new identity on every build and silently invalidates the grants.
#
# Two modes, chosen by the identity name:
#   local         "Ensemble Local Signing" (default) or any other name: no hardened runtime, no secure timestamp.
#   distribution  a name starting with "Developer ID Application": hardened runtime + secure timestamp (both required
#                 for notarization).
IDENTITY_NAME="${ENSEMBLE_SIGN_IDENTITY:-Ensemble Local Signing}"
# Compatibility with the app's earlier working name: a Mac that was set up before the rename holds its Camera and
# Accessibility grants against the signature of "Clutch Local Signing". Signing with a different certificate would
# make macOS ask for both again, so when the default identity is absent and the old one exists, the old one is used.
# An explicit ENSEMBLE_SIGN_IDENTITY is never overridden.
LEGACY_LOCAL_IDENTITY="Clutch Local Signing"
if [ -z "${ENSEMBLE_SIGN_IDENTITY:-}" ]; then
  LOCAL_IDENTITIES="$(security find-identity -p codesigning 2>/dev/null || true)"
  if ! grep -qF "\"$IDENTITY_NAME\"" <<<"$LOCAL_IDENTITIES" && grep -qF "\"$LEGACY_LOCAL_IDENTITY\"" <<<"$LOCAL_IDENTITIES"; then
    IDENTITY_NAME="$LEGACY_LOCAL_IDENTITY"
  fi
fi
ENTITLEMENTS="Sources/Ensemble/Ensemble.entitlements"
case "$IDENTITY_NAME" in
  -)
    # CI only (ENSEMBLE_SIGN_IDENTITY=-): an ad-hoc signature so the size and network checks run on a real bundle.
    # Such a build is never installed or uploaded: its signature changes every build, which would drop the grants.
    MODE="adhoc"
    HASHES="-"
    ;;
  "Developer ID Application"*)
    MODE="distribution"
    HASHES="$(security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$IDENTITY_NAME" | awk '{print $2}' | sort -u || true)"
    ;;
  *)
    MODE="local"
    HASHES="$(security find-identity -p codesigning 2>/dev/null | grep -F "\"$IDENTITY_NAME\"" | awk '{print $2}' | sort -u || true)"
    ;;
esac
# A secure timestamp is a request to Apple's timestamp server, so it is only used for distribution signing.
# Hardened runtime is distribution-only too: with a self-signed identity it cannot load Sparkle (no shared Team ID).
if [ "$MODE" = "distribution" ]; then
  SIGN_FLAGS=(--options runtime --timestamp)
else
  SIGN_FLAGS=(--timestamp=none)
fi
COUNT="$(printf '%s' "$HASHES" | grep -c . || true)"
if [ "$COUNT" -eq 0 ]; then
  echo "error: no code-signing identity named \"$IDENTITY_NAME\" in the keychain." | tee -a "$LOG" >&2
  echo "       Create it (Keychain Access > Certificate Assistant > Create a Certificate, type Code Signing) or set ENSEMBLE_SIGN_IDENTITY." | tee -a "$LOG" >&2
  exit 1
elif [ "$COUNT" -gt 1 ]; then
  echo "error: $COUNT identities are named \"$IDENTITY_NAME\"; delete the extras so the choice is unambiguous:" | tee -a "$LOG" >&2
  echo "$HASHES" | tee -a "$LOG" >&2
  exit 1
fi
IDENTITY="$HASHES"
echo "[$(date -u +%FT%TZ)] signing ($MODE) with \"$IDENTITY_NAME\" ($IDENTITY) flags: ${SIGN_FLAGS[*]}" | tee -a "$LOG"

# Inside-out: nested code first, then the framework, then the app. No --deep (it is deprecated for signing and
# would also overwrite entitlements that nested code ships with).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign() { codesign --force --sign "$IDENTITY" "${SIGN_FLAGS[@]}" "$@" 2>&1 | tee -a "$LOG"; }
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --entitlements "$ENTITLEMENTS" "$APP"

codesign --verify --deep --strict "$APP" 2>&1 | tee -a "$LOG"

if [ "$MODE" = "adhoc" ]; then
  echo "[$(date -u +%FT%TZ)] ad-hoc signed for CI checks only" | tee -a "$LOG"
  echo "$ROOT/$APP"
  exit 0
fi
REQ="$(codesign -dr - "$APP" 2>&1 | sed -n 's/^designated => //p')"
if [ -z "$REQ" ]; then
  echo "error: could not read the designated requirement" | tee -a "$LOG" >&2
  exit 1
fi
if [ "$MODE" = "local" ]; then
  REQ_FILE="build/designated-requirement.txt"
  if [ -f "$REQ_FILE" ] && [ "$(cat "$REQ_FILE")" != "$REQ" ]; then
    echo "WARNING: the designated requirement changed since the last build; macOS will ask for Camera and Accessibility again." | tee -a "$LOG" >&2
    echo "  was: $(cat "$REQ_FILE")" | tee -a "$LOG" >&2
    echo "  now: $REQ" | tee -a "$LOG" >&2
  fi
  printf '%s\n' "$REQ" > "$REQ_FILE"
fi
echo "[$(date -u +%FT%TZ)] designated requirement: $REQ" | tee -a "$LOG"
echo "$ROOT/$APP"
