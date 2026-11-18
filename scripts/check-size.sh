#!/bin/bash
# Fails (exit 1) if the built app is larger than the budget. The size is the sum of every file's bytes in
# build/Ensemble.app, so it does not move with disk block rounding. Measured 2026-10-14 after the size work: 7,160,670 bytes. The tour's 3D scenes (three.js, its glTF loader and IK solver, the scene module and the hand model) add about 225,000 bytes packed, and the budget rose from 7,600,000 to 7,800,000 for them. Per-screen calibration and saved positions took it from 8,000,000 to 8,100,000 (about 45,000 bytes of app code). The tour's new scene module and the owner's recorded hand motion (capture-default.js, 290 KB raw, 43,016 bytes LZMA-packed) grew the bundle by about 54,000 bytes packed, and the budget rose from 8,100,000 to 8,160,000 for them. The 60 Hz dot spring, camera format choice and the second dictation-safety batch (about 50,000 bytes of app code) took it to 8,250,000. The menu panel reorder, the combined update button and transient refusal notes took it to 8,300,000. The screen arrangement view (menu panel and Settings, Calibration) and the Actions tab add about 53,000 bytes of app code (stripped release binary 1,876,896 to 1,929,536 bytes, measured 2026-10-15), so the budget rose to 8,350,000. Taking over a dictation Claude started, the dictated-pane check and the thumbs-up send as one motion took the app to 8,380,514 bytes (CI, 2026-10-15), so the budget rose to 8,400,000.
# The peace-sign session widths (gesture rules, divider drag) took it from 8,400,000 to 8,450,000. Pausing while the
# keyboard or mouse is in use took the app to 8,427,506 bytes; fitting the focused session to the chat column adds
# 36,752 bytes of stripped release binary (2,037,256 to 2,074,008, measured 2026-10-15), so the budget rose to 8,480,000.
# Keyboard divider control for session widths (planner, focus hand-back, own-key windows) took it from 8,480,000 to 8,500,000.
# The one-click update interface adds 56,416 bytes of stripped binary to the 8,489,042-byte app (CI 2026-10-15), so 8,560,000.
# 2026-10-15: set to 9,000,000 (app about 8.55 MB) so parallel pull requests stop colliding on this line; a single change that adds over 100 KB still needs a stated reason.
# Raise BUDGET_BYTES in the same change that adds a heavier dependency or asset, and say why in the commit message.
#
# Usage: scripts/check-size.sh [path to Ensemble.app]
set -u
cd "$(dirname "$0")/.."

# 2026-10-23: raised to 9,500,000 with the app at 8,880,391 bytes (about 66,000 bytes a day over the last 5 days), so a feature pull request does not stall or collide on this line.
BUDGET_BYTES=9500000
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
