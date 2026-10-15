#!/bin/bash
# Fails (exit 1) if the built app is larger than the budget. The size is the sum of every file's bytes in
# build/Ensemble.app, so it does not move with disk block rounding. Measured 2026-10-14 after the size work: 7,160,670 bytes.
# Raise BUDGET_BYTES in the same change that adds a heavier dependency or asset, and say why in the commit message.
#
# Usage: scripts/check-size.sh [path to Ensemble.app]
set -u
cd "$(dirname "$0")/.."

BUDGET_BYTES=7700000
APP="${1:-build/Ensemble.app}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

[ -d "$APP" ] || { log "no app at $APP; run scripts/bundle.sh first"; exit 2; }
SIZE=$(find "$APP" -type f -print0 | xargs -0 stat -f %z | awk '{ s += $1 } END { print s + 0 }')
log "$APP is $SIZE bytes; budget $BUDGET_BYTES"
if [ "$SIZE" -gt "$BUDGET_BYTES" ]; then
  log "FAIL: over the budget by $((SIZE - BUDGET_BYTES)) bytes. Largest files:"
  find "$APP" -type f -print0 | xargs -0 stat -f '%z %N' | sort -rn | head -8
  exit 1
fi
log "PASS: $((BUDGET_BYTES - SIZE)) bytes of headroom"
