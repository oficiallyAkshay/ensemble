#!/bin/bash
# One run of the usage monitor: reads the anonymous daily summaries from PostHog, checks them against the rules, and files
# or updates one Linear ticket per firing rule. Run every 2 hours by the dev.ensemble.usage-monitor launchd agent that
# scripts/install-usage-monitor.sh writes; no Claude session or routine is involved (docs/telemetry.md, "Reading the data").
#   scripts/usage-monitor.sh
# The three secrets are read at run time from the 1Password command-line tool and handed to the one process that needs
# each, through its environment. Nothing is written to disk or printed, and nothing is kept in the repository.
# Every run that reaches the analysis logs one summary line (days since the last kept report, installs, events kept and
# discarded, rules with enough data), so thin data is visible. A run with no firing rule or alert files nothing and exits 0.
# A key that cannot be read exits 1; the second such failure in a row is filed, unless it is the Linear key.
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
log_lines() { while IFS= read -r line; do [ -n "$line" ] && say "$line"; done <<< "$1"; }

# All three are read before any is acted on, so a failed read can still be filed through the Linear key. The error
# line text is fixed: usage-triage.py --key-alert-from-log recognises it.
FAILED=""
PH_KEY="$(op read "$POSTHOG_KEY_REF" 2>/dev/null)" || FAILED="${FAILED:-the PostHog read key}"
PH_PROJECT="$(op read "$POSTHOG_PROJECT_REF" 2>/dev/null)" || FAILED="${FAILED:-the PostHog project id}"
LINEAR_KEY="$(op read "$LINEAR_KEY_REF" 2>/dev/null)" || { FAILED="${FAILED:-the Linear key}"; LINEAR_KEY=""; }
if [ -n "$FAILED" ]; then
  say "error: could not read $FAILED from 1Password"
  # The second failure in a row is filed. If the Linear key is the unreadable one nothing can be filed: the log line is the signal.
  if [ -n "$LINEAR_KEY" ]; then
    ALERT="$(/usr/bin/python3 -I "$ROOT/scripts/usage-triage.py" --key-alert-from-log "$LOG" 2>>"$LOG")"
    if [ -n "$ALERT" ]; then
      log_lines "$(printf '%s' "$ALERT" | LINEAR_API_KEY="$LINEAR_KEY" /usr/bin/python3 -I "$ROOT/scripts/usage-file-tickets.py" 2>>"$LOG")"
    fi
  fi
  exit 1
fi

# The analysis output is held in memory, not in a file, and only the filing step sees the Linear key.
REPORT="$(POSTHOG_PERSONAL_API_KEY="$PH_KEY" POSTHOG_PROJECT_ID="$PH_PROJECT" /usr/bin/python3 -I "$ROOT/scripts/usage-triage.py" --json 2>>"$LOG")" \
  || { say "error: the usage analysis failed (message above)"; exit 1; }
RESULT="$(printf '%s' "$REPORT" | LINEAR_API_KEY="$LINEAR_KEY" /usr/bin/python3 -I "$ROOT/scripts/usage-file-tickets.py" 2>>"$LOG")"
STATUS=$?
log_lines "$RESULT"
[ "$STATUS" = 0 ] || say "error: filing finished with status $STATUS (message above)"
exit "$STATUS"
