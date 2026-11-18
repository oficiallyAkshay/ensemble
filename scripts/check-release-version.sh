#!/bin/bash
# Refuses a release that would skip a version or not raise the build number, judged against the published appcast:
#   bash scripts/check-release-version.sh <appcast.xml> <version> <build>
# Sparkle installs the item with the highest build number, so a build at or below the newest published one reaches
# nobody. The version must be the next patch, minor or major of the newest X.Y.Z in the feed (after 1.2.3: 1.2.4, 1.3.0
# or 2.0.0). To jump on purpose, name the version being skipped: ENSEMBLE_SKIP_VERSION=1.2.4 lets 1.2.5 follow 1.2.3.
# An empty or missing appcast (the first release) accepts any X.Y.Z. Build numbers are commit counts and jump, so only
# "strictly greater" is checked, never contiguous. Old gaps in the feed do not matter: only the highest item is judged.
set -euo pipefail

USAGE="usage: scripts/check-release-version.sh <appcast.xml> <version> <build>"
FEED="${1:?$USAGE}"
VERSION="${2:?$USAGE}"
BUILD="${3:?$USAGE}"

is_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
successors() { local a b c; IFS=. read -r a b c <<<"$1"; echo "$a.$b.$((10#$c + 1)) $a.$((10#$b + 1)).0 $((10#$a + 1)).0.0"; }
follows() { [[ " $(successors "$2") " == *" $1 "* ]]; }

is_version "$VERSION" || { echo "error: version $VERSION is not of the form X.Y.Z" >&2; exit 1; }
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "error: build $BUILD is not a number" >&2; exit 1; }

# Read once: the caller may pass a process substitution, which can be read a single time.
XML="$(cat "$FEED" 2>/dev/null || true)"
# The feed may list items in any order and hold pre-release versions: take the highest of each, not the first item.
TOP_BUILD="$(sed -n 's|.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*|\1|p' <<<"$XML" | sort -n | tail -1)"
TOP_VERSION="$(sed -n 's|.*<sparkle:shortVersionString>\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)</sparkle:shortVersionString>.*|\1|p' <<<"$XML" \
  | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"

if [ -n "$TOP_BUILD" ] && [ "$((10#$BUILD))" -le "$((10#$TOP_BUILD))" ]; then
  echo "error: build $BUILD is not above the newest published build $TOP_BUILD; installed copies would never take it" >&2
  exit 1
fi
if [ -n "$TOP_VERSION" ] && ! follows "$VERSION" "$TOP_VERSION"; then
  SKIP="${ENSEMBLE_SKIP_VERSION:-}"
  if [ -n "$SKIP" ] && is_version "$SKIP" && follows "$SKIP" "$TOP_VERSION" && follows "$VERSION" "$SKIP"; then
    echo "skipping version $SKIP on purpose (ENSEMBLE_SKIP_VERSION): $VERSION follows $TOP_VERSION"
  else
    read -r p m M <<<"$(successors "$TOP_VERSION")"
    echo "error: version $VERSION does not follow the newest published $TOP_VERSION; expected $p, $m or $M" \
      "(to skip one on purpose, name it: ENSEMBLE_SKIP_VERSION=$p)" >&2
    exit 1
  fi
fi
echo "version $VERSION build $BUILD follows the newest published ${TOP_VERSION:-none} build ${TOP_BUILD:-none}"
