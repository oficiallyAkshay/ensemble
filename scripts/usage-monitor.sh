#!/bin/bash
# One run of the usage monitor: reads the anonymous daily summaries from PostHog, checks them against the rules, and files
# or updates one Linear ticket per firing rule. Run every 2 hours by the dev.ensemble.usage-monitor launchd agent that
# scripts/install-usage-monitor.sh writes; no Claude session or routine is involved (docs/telemetry.md, "Reading the data").
#   scripts/usage-monitor.sh
# The three secrets are read at run time from the 1Password command-line tool and handed to the one process that needs
# each, through its environment. Nothing is written to disk or printed, and nothing is kept in the repository.
# A run with thin data, or with no firing rule, files nothing and exits 0.
# Log: ~/Library/Logs/Ensemble/usage-monitor.log (UTC, one line per result; no key ever reaches it).
# Settings, all optional: ENSEMBLE_USAGE_OP_POSTHOG_KEY, ENSEMBLE_USAGE_OP_POSTHOG_PROJECT, ENSEMBLE_USAGE_OP_LINEAR_KEY
# (1Password secret references, "op://vault/item/field"), ENSEMBLE_USAGE_LOG_DIR.
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${ENSEMBLE_USAGE_LOG_DIR:-$HOME/Library/Logs/Ensemble}"
LOG="$LOG_DIR/usage-monitor.log"
POSTHOG_KEY_REF="${ENSEMBLE_USAGE_OP_POSTHOG_KEY:-op://Ensemble/PostHog read key/credential}"
POSTHOG_PROJECT_REF="${ENSEMBLE_USAGE_OP_POSTHOG_PROJECT:-op://Ensemble/PostHog read key/project id}"
LINEAR_KEY_REF="${ENSEMBLE_USAGE_OP_LINEAR_KEY:-op://Ensemble/Linear API key/credential}"

mkdir -p "$LOG_DIR"
say() { echo "[$(date -u +%FT%TZ)] $*" >> "$LOG"; }

command -v op >/dev/null || { say "error: the 1Password command-line tool (op) is missing"; exit 1; }
PH_KEY="$(op read "$POSTHOG_KEY_REF" 2>/dev/null)" || { say "error: could not read the PostHog read key from 1Password"; exit 1; }
PH_PROJECT="$(op read "$POSTHOG_PROJECT_REF" 2>/dev/null)" || { say "error: could not read the PostHog project id from 1Password"; exit 1; }
LINEAR_KEY="$(op read "$LINEAR_KEY_REF" 2>/dev/null)" || { say "error: could not read the Linear key from 1Password"; exit 1; }

# The analysis output is held in memory, not in a file, and only the filing step sees the Linear key.
REPORT="$(POSTHOG_PERSONAL_API_KEY="$PH_KEY" POSTHOG_PROJECT_ID="$PH_PROJECT" /usr/bin/python3 -I "$ROOT/scripts/usage-triage.py" --json 2>>"$LOG")" \
  || { say "error: the usage analysis failed (message above)"; exit 1; }
RESULT="$(printf '%s' "$REPORT" | LINEAR_API_KEY="$LINEAR_KEY" /usr/bin/python3 -I "$ROOT/scripts/usage-file-tickets.py" 2>>"$LOG")"
STATUS=$?
while IFS= read -r line; do [ -n "$line" ] && say "$line"; done <<< "$RESULT"
[ "$STATUS" = 0 ] || say "error: filing finished with status $STATUS (message above)"
exit "$STATUS"
