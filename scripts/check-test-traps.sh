#!/bin/bash
# Fails (exit 1) and lists file:line if a Swift test makes a mutating call the WHOLE of its expectation, for example
#     var s = StillFace()
#     #expect(s.record(change: 0))
# Swift Testing's #expect macro captures its argument as an expression and cannot take a mutating call on a local
# `var` there; the Command Line Tools cannot run the macro (docs/gotchas.md, 13), so CI is the first place this would
# fail to compile, after a push. Run the call on its own line, keep the result in a `let`, then expect on that.
#
# Narrow on purpose: only a line whose #expect( or #require( holds exactly one call, `receiver.method(...)`, with the
# receiver a `var` declared earlier in the same function and the method declared `mutating func` somewhere under
# Sources/ (the script never sees types, so a method name is the best it can know). A mutating call used as setup, or
# inside a larger expectation (`#expect(s.update(x) == y)`, which builds on main today), is not flagged. A name shared by
# a mutating and a non-mutating method can be marked with a trailing `// trap-ok` comment. An expectation that runs over
# several lines is not read.
#
# Runs before every push through pre-commit (.pre-commit-config.yaml; install it with
# `pre-commit install --hook-type pre-push`). By hand: scripts/check-test-traps.sh [file or folder ...]
# With no arguments it reads Tests/.
set -u
cd "$(dirname "$0")/.."

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

[ "$#" -gt 0 ] || set -- Tests
FILES=$(find "$@" -name '*.swift' -type f 2>/dev/null | sort) || true
[ -n "$FILES" ] || { log "no Swift files under: $*"; exit 2; }

MUTATING=$(grep -rhoE 'mutating (@[A-Za-z]+ )?func [A-Za-z_][A-Za-z0-9_]*' Sources 2>/dev/null | awk '{ print $NF }' | sort -u | tr '\n' ' ')

HITS=$(echo "$FILES" | while IFS= read -r f; do
  awk -v file="$f" -v mutating="$MUTATING" '
    BEGIN { n = split(mutating, m, " "); for (i = 1; i <= n; i++) mut[m[i]] = 1 }
    /^[ \t]*\/\// { next }
    /(^|[ \t])func [A-Za-z_]/ { delete vars }
    {
      line = $0
      if (match(line, /(^|[ \t;{])var [A-Za-z_][A-Za-z0-9_]*/)) {
        decl = substr(line, RSTART, RLENGTH); sub(/.*var /, "", decl); vars[decl] = 1
      }
      if (line ~ /trap-ok/) next
      if (!match(line, /#(expect|require)\(/)) next
      rest = substr(line, RSTART + RLENGTH)
      sub(/^[ \t]+/, "", rest); sub(/^(try|await) /, "", rest); sub(/^!/, "", rest); sub(/^[ \t]+/, "", rest)
      if (!match(rest, /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+\(/)) next
      path = substr(rest, 1, RLENGTH - 1)
      split(path, parts, ".")
      if (!(parts[1] in vars) || !(parts[length(parts)] in mut)) next
      tail = substr(rest, RLENGTH + 1); depth = 1; instr = 0; end = 0
      for (i = 1; i <= length(tail); i++) {
        c = substr(tail, i, 1)
        if (c == "\\" && instr) { i++; continue }
        if (c == "\"") { instr = !instr; continue }
        if (instr) continue
        if (c == "(") depth++
        else if (c == ")") { depth--; if (depth == 0) { end = i; break } }
      }
      if (end == 0) next
      after = substr(tail, end + 1); sub(/^[ \t]+/, "", after)
      if (after ~ /^[),]/) printf "%s:%d: the whole expectation is the mutating call %s on the var %s: %s\n", file, NR, parts[length(parts)], parts[1], line
    }' "$f"
done)

if [ -n "$HITS" ]; then
  log "FAIL: a mutating call is the whole expectation (docs/gotchas.md, 21). Call it on its own line, keep the result in a let, then expect on that:"
  echo "$HITS"
  exit 1
fi
log "PASS: no test makes a call on a local var the whole of its expectation"
