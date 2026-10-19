#!/bin/bash
# Fails (exit 1) and lists file:line if the app's code or web assets contain a network API or an http(s)/ws(s)/ftp URL
# that is not on the allowlist below (the Sparkle update feed and the anonymous usage report, nothing else). When build/Ensemble.app exists, the built executable and the unpacked web assets
# are scanned against the same allowlist.
#
# The face tracker page is also blocked from the network at run time (Sources/Ensemble/Engine/NetworkBlock.swift);
# this script is the second guard: it keeps network code from entering the source tree at all.
#
# Usage: scripts/check-network.sh
set -u
cd "$(dirname "$0")/.."

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

WEB="Sources/Ensemble/Resources/web"
APP="build/Ensemble.app"
BUNDLE_WEB="$APP/Contents/Resources/web"

URL_RE='(https?|wss?|ftp)://[^[:space:]"<>)]*'
SWIFT_API_RE='URLSession|NSURLConnection|URLRequest|NWConnection|NWListener|NWBrowser|NWPathMonitor|import Network|CFNetwork|CFHTTP|CFSocket|CFStream|CFReadStream|CFWriteStream|NSStream|getStreamsToHost|NetService|MultipeerConnectivity|getaddrinfo|gethostbyname|[^A-Za-z_.]socket\(|WebSocket|SCNetworkReachability'
WEB_API_RE='fetch\(|XMLHttpRequest|sendBeacon|WebSocket|EventSource|importScripts|RTCPeerConnection|WebTransport'
# MediaPipe's own loader uses these to read its wasm, model and worker script; the page can only reach ensemble-asset
# and the compiled block list refuses everything else. The other web APIs above stay forbidden in these files.
VENDORED_API_RE='sendBeacon|WebSocket|EventSource|RTCPeerConnection|WebTransport'
# head.js fetches each camera frame from the app's own scheme (BASE is ensemble-asset://local; the page's CSP allows
# connect-src ensemble-asset: only), so the frame stays in memory between the app and the page. Its fetch is allowed only
# while every fetch in head.js is that one call (checked below).
# three.js reads the tour's hand model through its own loader (XMLHttpRequest or fetch of ensemble-asset://, nothing else is
# reachable: the tour page gets the same compiled block list). It is held to the same list as MediaPipe's loader.
VENDORED="vision_bundle.mjs wasm/vision_wasm_internal.js tour/three.min.js"
NATIVE_SYMBOL_RE='URLSession|NSURLConnection|NWConnection|nw_connection|CFSocket|CFHTTP|getaddrinfo|gethostbyname|CFStreamCreatePairWithSocketToHost'

# Usage reporting (docs/telemetry.md) is the one other network use, and it is confined to UsageReporter.swift: that file may
# use URLSession and may name the PostHog capture URL and no other. Moving to another PostHog region changes the host here.

# Allowlist: <path suffix> TAB <regex the matched text must satisfy>. Every entry is a decision; keep each narrow.
ALLOW=$(cat <<'EOF'
Sources/Ensemble/App/UpdateController.swift	^https://[^/]+/.*appcast\.xml$
Sources/Ensemble/App/UsageReporter.swift	^https://us\.i\.posthog\.com/i/v0/e/$
Sources/Ensemble/App/UsageReporter.swift	URLSession|URLRequest
Info.plist	^http://www\.apple\.com/DTDs/PropertyList-1\.0\.dtd$
Ensemble.entitlements	^http://www\.apple\.com/DTDs/PropertyList-1\.0\.dtd$
Sources/Ensemble/Engine/FaceTracker.swift	AssetSchemeHandler\.scheme
Sources/Ensemble/App/Tour/TourSceneView.swift	AssetSchemeHandler\.scheme
web/head.js	^fetch\($
Sources/Ensemble/Engine/NetworkBlock.swift	url-filter
Sources/Ensemble/Engine/NetworkBlock.swift	^(https?|wss?|ftp)://
web/wasm/vision_wasm_internal.wasm	^http://go/lsc_proto3_utf8$
web/wasm/vision_wasm_internal.wasm	^http://goto/weakfields$
web/wasm/vision_wasm_internal.wasm	^https://github\.com/opencv/opencv/issues/16739$
web/wasm/vision_wasm_internal.wasm	^https://www\.tensorflow\.org/lite/guide/ops_(custom|select)$
web/tour/three.min.js	^http://www\.w3\.org/1999/xhtml$
web/tour/GLTFLoader.js	^https://github\.com/(KhronosGroup/glTF|mrdoob/three\.js)/
web/tour/GLTFLoader.js	^http://,https://,//$
web/tour/GLTFLoader.js	^https://en\.wikipedia\.org/wiki/Portable_Network_Graphics#File_header$
web/tour/CCDIKSolver.js	^https://sites\.google\.com/site/auraliusproject/ccd-algorithm$
web/tour/CCDIKSolver.js	^http://www20\.atpages\.jp/katwat/three\.js_r58/
MacOS/Ensemble	^https://[^/]+/.*appcast\.xml$
MacOS/Ensemble	^http://www\.apple\.com/DTDs/PropertyList-1\.0\.dtd$
MacOS/Ensemble	^https://us\.i\.posthog\.com/i/v0/e/$
MacOS/Ensemble	^ *_[^ ]*NSURLSession
MacOS/Ensemble	^(https?|wss?|ftp)://$
EOF
)

FOUND=$(mktemp)
trap 'rm -f "$FOUND"; [ -n "${UNPACKED:-}" ] && rm -rf "$UNPACKED"' EXIT

allowed() {
  local file=$1 text=$2 suffix re
  while IFS=$'\t' read -r suffix re; do
    [ -n "$suffix" ] || continue
    if [[ $file == *"$suffix" ]] && [[ $text =~ $re ]]; then return 0; fi
  done <<< "$ALLOW"
  return 1
}

# report <why> reads "file:line:text" lines on stdin and records those not on the allowlist.
report() {
  local why=$1 file line text
  while IFS=: read -r file line text; do
    allowed "$file" "$text" && continue
    echo "$file:$line: $why: ${text:0:160}" >> "$FOUND"
  done
}

scan_web_folder() {
  local dir=$1 f rel api
  log "web assets in $dir"
  while IFS= read -r f; do
    rel=${f#"$dir"/}
    case "$f" in
      *.html|*.js|*.mjs)
        grep -HnoE "$URL_RE" "$f" | report "URL"
        api=$WEB_API_RE
        case " $VENDORED " in *" $rel "*) api=$VENDORED_API_RE ;; esac
        grep -HnoE "$api" "$f" | report "network API"
        if [ "$rel" = head.js ]; then
          grep -Hn 'fetch(' "$f" | grep -vF "fetch(BASE + '/frame/' + number)" | report "fetch other than the frame fetch"
        fi
        ;;
      *)
        strings -a -n 6 "$f" | grep -noE "$URL_RE" | sed "s|^|$f:|" | report "URL in binary"
        ;;
    esac
  done < <(find "$dir" -type f | sort)
}

log "Swift sources"
SWIFT_FILES=$(find Sources -name '*.swift' | sort)
# shellcheck disable=SC2086
grep -HnoE "$URL_RE" $SWIFT_FILES | report "URL"
# shellcheck disable=SC2086
grep -HnE "$SWIFT_API_RE" $SWIFT_FILES | report "network API"

log "plists and entitlements"
PLISTS=$(find Sources -name '*.plist' -o -name '*.entitlements' | sort)
# shellcheck disable=SC2086
[ -z "$PLISTS" ] || grep -HnoE "$URL_RE" $PLISTS | report "URL"

scan_web_folder "$WEB"

if [ -d "$APP" ]; then
  EXE="$APP/Contents/MacOS/Ensemble"
  log "built executable $EXE"
  strings -a -n 6 "$EXE" | grep -noE "$URL_RE" | sed "s|^|$EXE:|" | report "URL in executable"
  nm -u "$EXE" 2>/dev/null | grep -E "$NATIVE_SYMBOL_RE" | sed "s|^|$EXE:0:|" | report "network symbol in executable"
  # Nothing about the build machine ships: no home-folder path (which carries the account name) anywhere in the app.
  grep -rlaE "/Users/[^/[:space:]]+/" "$APP" 2>/dev/null | sed "s|^|build-machine path in |" >> "$FOUND"
  if [ -d "$BUNDLE_WEB" ]; then
    UNPACKED=$(mktemp -d)
    log "unpack $BUNDLE_WEB"
    if swift scripts/pack-web.swift --unpack "$BUNDLE_WEB" "$UNPACKED/web" > /dev/null; then
      scan_web_folder "$UNPACKED/web"
    else
      echo "$BUNDLE_WEB: cannot unpack the packed web assets to scan them" >> "$FOUND"
    fi
  fi
else
  log "no built app at $APP; scanned the source tree only"
fi

if [ -s "$FOUND" ]; then
  log "FAIL: network use outside the allowlist"
  sed "s|${UNPACKED:-/nonexistent}/web|$BUNDLE_WEB (unpacked)|" "$FOUND"
  exit 1
fi
log "PASS: no network API or URL outside the allowlist"
