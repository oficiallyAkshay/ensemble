#!/bin/bash
# Installs the agent that releases Ensemble by itself after a merge changes app logic (scripts/auto-release.sh).
#   scripts/install-auto-release.sh              write ~/Library/LaunchAgents/dev.ensemble.releaser.plist and load it
#   scripts/install-auto-release.sh --dry-run    print the plist that would be written; change nothing
#   scripts/install-auto-release.sh --uninstall  unload the agent and remove the plist
# The agent runs every 5 minutes. Each run first fetches origin/main in the checkout below, then runs the copy of
# scripts/auto-release.sh that sits on origin/main, so a checkout whose own files are stale still releases with the
# current script. It signs with the login keychain, so it runs as you on this Mac (docs/RELEASING.md).
# Log: ~/Library/Logs/Ensemble/releaser.log   Agent output: ~/Library/Logs/Ensemble/releaser.out
# Off switch: launchctl bootout "gui/$(id -u)/dev.ensemble.releaser"   (or: scripts/install-auto-release.sh --uninstall)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="dev.ensemble.releaser"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/Ensemble"
say() { echo "[$(date -u +%FT%TZ)] $*"; }

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$AGENT"
  say "the releaser is off and its agent file is removed; releases are cut by hand again (docs/RELEASING.md)"
  exit 0
fi
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

command -v git >/dev/null || { echo "git is missing (xcode-select --install)." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is missing (brew install jq)." >&2; exit 1; }
GH="$(command -v gh || true)"
[ -n "$GH" ] || { echo "gh is missing (brew install gh), then gh auth login." >&2; exit 1; }
[ "$DRY" = 1 ] || gh auth status >/dev/null 2>&1 || { echo "gh is not signed in; run gh auth login first." >&2; exit 1; }
git -C "$ROOT" rev-parse -q --verify refs/remotes/origin/main >/dev/null || git -C "$ROOT" fetch --quiet origin main

# macOS refuses background agents access to Desktop, Documents and Downloads (the agent exits 126), so a checkout kept
# there gets a separate clone for the agent, as scripts/dev-install.sh does. The agent only fetches into it and makes
# throwaway worktrees of origin/main; nobody develops in it.
REPO="$ROOT"
case "$ROOT/" in
  "$HOME/Desktop/"*|"$HOME/Documents/"*|"$HOME/Downloads/"*)
    REPO="$HOME/Library/Application Support/Ensemble/releaser-checkout"
    if [ "$DRY" = 0 ] && [ ! -d "$REPO/.git" ]; then
      say "this checkout is in a folder macOS hides from background agents; cloning a copy to $REPO"
      mkdir -p "$(dirname "$REPO")"
      git clone --quiet "$(git -C "$ROOT" remote get-url origin)" "$REPO"
    fi
    ;;
esac

# What the agent runs: refresh origin/main, take the script from it, run it. A failure to read it stops the run
# (an empty script piped to bash would "succeed" and release nothing without saying so).
RUN='git -C "$ENSEMBLE_RELEASER_REPO" fetch --quiet origin +refs/heads/main:refs/remotes/origin/main || exit 0; s=$(git -C "$ENSEMBLE_RELEASER_REPO" show origin/main:scripts/auto-release.sh) || exit 1; exec bash -c "$s" auto-release'

# Written with PlistBuddy, which escapes XML for us (as scripts/dev-install.sh does); it drops bare double quotes, so
# the command's are backslash-escaped.
write_agent() {
  local out="$1" pb=/usr/libexec/PlistBuddy
  rm -f "$out"
  "$pb" -c "Add :Label string $LABEL" "$out" >/dev/null
  "$pb" -c "Add :ProgramArguments array" "$out"
  "$pb" -c "Add :ProgramArguments:0 string /bin/bash" "$out"
  "$pb" -c "Add :ProgramArguments:1 string -c" "$out"
  "$pb" -c "Add :ProgramArguments:2 string ${RUN//\"/\\\"}" "$out"
  "$pb" -c "Add :EnvironmentVariables dict" "$out"
  "$pb" -c "Add :EnvironmentVariables:ENSEMBLE_RELEASER_REPO string $REPO" "$out"
  "$pb" -c "Add :EnvironmentVariables:PATH string /opt/homebrew/bin:$(dirname "$GH"):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$out"
  "$pb" -c "Add :StartInterval integer 300" "$out"
  "$pb" -c "Add :RunAtLoad bool true" "$out"
  "$pb" -c "Add :ProcessType string Background" "$out"
  "$pb" -c "Add :StandardOutPath string $LOG_DIR/releaser.out" "$out"
  "$pb" -c "Add :StandardErrorPath string $LOG_DIR/releaser.out" "$out"
  plutil -lint "$out" >/dev/null
}

if [ "$DRY" = 1 ]; then
  TMP="$(mktemp -d)"; write_agent "$TMP/$LABEL.plist"; plutil -convert xml1 -o - "$TMP/$LABEL.plist"; rm -rf "$TMP"
  say "dry run: nothing was written or loaded"
  exit 0
fi

mkdir -p "$(dirname "$AGENT")" "$LOG_DIR"
write_agent "$AGENT"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"
say "done. Ensemble releases itself within about 5 minutes of the checks passing on a merge that changes app logic."
say "log: ~/Library/Logs/Ensemble/releaser.log"
say "off switch: launchctl bootout \"gui/\$(id -u)/$LABEL\"   (or scripts/install-auto-release.sh --uninstall)"
