#!/bin/bash
# Prints PASS when two copies of the app carry the same designated requirement, and FAIL with both values when they
# differ. Accessibility stays granted across an update only if the new app keeps the requirement the old one had, so
# run it with the installed app and the newest release before trusting an update:
#     bash scripts/check-update-signature.sh [installed app, default /Applications/Ensemble.app] <newer app or DMG>
# Exit 0 on PASS; 1 on FAIL; 2 on anything unreadable (a missing app, no requirement found): an unreadable value is never a PASS.
# A DMG is mounted read-only, without browsing, on a private folder, and detached on every exit path.
# It reads signatures only: no setting is changed, and it runs no tccutil or defaults (AGENTS.md, trust rules).
#
# Sourcing the file defines the functions and runs nothing, so the test (scripts/test-check-update-signature.sh) can
# feed compare_requirements two strings on a machine without codesign or a DMG.
set -u

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

# The text after "designated => " is the requirement; hex digits are compared without case, as ship-release.sh does.
compare_requirements() {
  local a="$1" b="$2"
  if [ -z "$a" ] || [ -z "$b" ]; then
    echo "FAIL: a designated requirement could not be read (installed: '$a'; newer: '$b')"
    return 2
  fi
  if [ "$(printf '%s' "$a" | tr 'A-F' 'a-f')" = "$(printf '%s' "$b" | tr 'A-F' 'a-f')" ]; then
    echo "PASS: both apps carry the designated requirement $a"
    return 0
  fi
  echo "FAIL: the designated requirements differ"
  echo "  installed: $a"
  echo "  newer:     $b"
  return 1
}

read_requirement() { codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'; }

MNT=""
cleanup() { [ -z "$MNT" ] || { hdiutil detach -quiet -force "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; }; }

main() {
  local installed="${1:-/Applications/Ensemble.app}" newer="${2:-}"
  [ -n "$newer" ] || { log "usage: bash scripts/check-update-signature.sh [installed app] <newer app or DMG>"; return 2; }
  [ -d "$installed" ] || { log "error: no app at $installed"; return 2; }
  [ -e "$newer" ] || { log "error: nothing at $newer"; return 2; }
  trap cleanup EXIT
  local newer_app="$newer"
  if [ -f "$newer" ]; then
    MNT="$(mktemp -d)"
    hdiutil attach -nobrowse -readonly -noverify -mountpoint "$MNT" "$newer" >/dev/null || { log "error: could not open $newer"; return 2; }
    newer_app="$(find "$MNT" -maxdepth 1 -name '*.app' -type d | head -1)"
    [ -n "$newer_app" ] || { log "error: no app inside $newer"; return 2; }
  fi
  local req_installed req_newer
  req_installed="$(read_requirement "$installed")"
  req_newer="$(read_requirement "$newer_app")"
  compare_requirements "$req_installed" "$req_newer"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit $?
fi
