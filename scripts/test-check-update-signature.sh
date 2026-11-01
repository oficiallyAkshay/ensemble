#!/bin/bash
# Tests scripts/check-update-signature.sh without codesign or a DMG: feeds compare_requirements fixture strings.
# Run from anywhere: bash scripts/test-check-update-signature.sh
set -u
cd "$(dirname "$0")/.."
# shellcheck source=check-update-signature.sh
source scripts/check-update-signature.sh

FAILS=0
check() { # name, expected exit, expected text, actual exit, actual output
  if [ "$4" -eq "$2" ] && printf '%s' "$5" | grep -qF -- "$3"; then echo "ok   $1"; else echo "FAIL $1: exit $4, output: $5"; FAILS=$((FAILS + 1)); fi
}

REQ_A='identifier "dev.ensemble.app" and certificate leaf = H"40b0779a528926b904971bbdb913dc4860cd1d49"'
REQ_B='identifier "dev.ensemble.app" and certificate leaf = H"0000000000000000000000000000000000000000"'

out="$(compare_requirements "$REQ_A" "$REQ_A")"; rc=$?
check "equal requirements print PASS" 0 "PASS" "$rc" "$out"

out="$(compare_requirements "$REQ_A" "$(printf '%s' "$REQ_A" | tr 'a-f' 'A-F')")"; rc=$?
check "hex case alone does not differ" 0 "PASS" "$rc" "$out"

out="$(compare_requirements "$REQ_A" "$REQ_B")"; rc=$?
check "different requirements print FAIL and exit 1" 1 "FAIL" "$rc" "$out"
check "FAIL shows the installed value" 1 "$REQ_A" "$rc" "$out"
check "FAIL shows the newer value" 1 "$REQ_B" "$rc" "$out"

out="$(compare_requirements "" "")"; rc=$?
check "two unreadable requirements are never a PASS" 2 "FAIL" "$rc" "$out"

out="$(compare_requirements "$REQ_A" "")"; rc=$?
check "one unreadable requirement is never a PASS" 2 "FAIL" "$rc" "$out"

out="$(bash scripts/check-update-signature.sh /nonexistent/Ensemble.app /nonexistent/new.dmg 2>&1)"; rc=$?
check "a missing app exits non-zero" 2 "no app at" "$rc" "$out"

[ "$FAILS" -eq 0 ] || { echo "$FAILS check(s) failed"; exit 1; }
echo "all checks passed"
