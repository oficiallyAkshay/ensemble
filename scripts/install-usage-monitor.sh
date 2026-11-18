#!/bin/bash
# Installs the agent that runs the usage monitor (scripts/usage-monitor.sh) every 2 hours.
#   scripts/install-usage-monitor.sh              write ~/Library/LaunchAgents/dev.ensemble.usage-monitor.plist and load it
#   scripts/install-usage-monitor.sh --dry-run    print the plist that would be written; change nothing
#   scripts/install-usage-monitor.sh --uninstall  unload the agent and remove the plist
# Needs the 1Password command-line tool (op), signed in, holding the PostHog read key, the PostHog project id and a Linear
# API key; the secret references the run uses are listed at the top of scripts/usage-monitor.sh. The agent runs this
# checkout's copy of the scripts, so keep the checkout outside Desktop, Documents and Downloads (macOS hides those from
# background agents).
# Log: ~/Library/Logs/Ensemble/usage-monitor.log
# Off switch: launchctl bootout "gui/$(id -u)/dev.ensemble.usage-monitor"   (or: scripts/install-usage-monitor.sh --uninstall)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="dev.ensemble.usage-monitor"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/Ensemble"
say() { echo "[$(date -u +%FT%TZ)] $*"; }

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$AGENT"
  say "the usage monitor is off and its agent file is removed"
  exit 0
fi
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

case "$ROOT/" in
  "$HOME/Desktop/"*|"$HOME/Documents/"*|"$HOME/Downloads/"*)
    echo "This checkout is in a folder macOS hides from background agents; use a checkout elsewhere." >&2; exit 1 ;;
esac
case "$ROOT$LOG_DIR" in
  *"|"*|*"&"*) echo "A path with | or & cannot be written into the agent file." >&2; exit 1 ;;
esac

render() { sed -e "s|__ROOT__|$ROOT|g" -e "s|__LOG_DIR__|$LOG_DIR|g" "$ROOT/scripts/$LABEL.plist"; }

if [ "$DRY" = 1 ]; then
  render
  say "dry run: nothing was written or loaded"
  exit 0
fi

command -v op >/dev/null || { echo "The 1Password command-line tool is missing (brew install 1password-cli)." >&2; exit 1; }
mkdir -p "$(dirname "$AGENT")" "$LOG_DIR"
render > "$AGENT"
plutil -lint "$AGENT" >/dev/null
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"
say "done. The usage monitor runs now and then every 2 hours."
say "log: ~/Library/Logs/Ensemble/usage-monitor.log"
say "off switch: launchctl bootout \"gui/\$(id -u)/$LABEL\"   (or scripts/install-usage-monitor.sh --uninstall)"
