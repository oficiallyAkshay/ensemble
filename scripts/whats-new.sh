#!/bin/bash
# The release summary shown in the update window ("What's new"): docs/whats-new/<version>.txt, written for every release.
#   scripts/whats-new.sh check <summary file>
#       Refuses a summary the app would not show: not 3 to 5 lines of "icon | heading | subheading", an empty field, or
#       an icon that is not a plain SF Symbol name (letters, digits, dots). Same rules as Sources/EnsembleCore/WhatsNew.swift.
#   scripts/whats-new.sh inject <appcast.xml> <archive file name> <summary file>
#       Adds the summary to the appcast item of that archive as a <whatsNew> element, so it travels in the update feed.
set -euo pipefail

check() {
  local file="${1:?usage: scripts/whats-new.sh check <summary file>}"
  [ -f "$file" ] || { echo "error: no release summary at $file; write 3 to 5 lines of \"icon | heading | subheading\" (docs/RELEASING.md)" >&2; return 1; }
  awk -F'|' '
    function trim(s) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); return s }
    /^[ \t\r]*$/ { next }
    {
      n++
      if (NF != 3 || trim($1) == "" || trim($2) == "" || trim($3) == "" || trim($1) !~ /^[A-Za-z0-9.]+$/) {
        printf "error: summary line %d is not \"icon | heading | subheading\" with an SF Symbol name: %s\n", NR, $0 > "/dev/stderr"
        bad = 1
      }
    }
    END {
      if (n < 3 || n > 5) { printf "error: the release summary has %d items; it needs 3 to 5\n", n > "/dev/stderr"; bad = 1 }
      exit bad
    }' "$file"
}

inject() {
  local appcast="${1:?usage: scripts/whats-new.sh inject <appcast.xml> <archive> <summary file>}"
  local archive="${2:?}" file="${3:?}"
  check "$file"
  local out
  out="$(mktemp)"
  awk -v archive="$archive" -v file="$file" '
    BEGIN {
      while ((getline line < file) > 0) {
        if (line ~ /^[ \t\r]*$/) continue
        gsub(/&/, "\\&amp;", line); gsub(/</, "\\&lt;", line); gsub(/>/, "\\&gt;", line)
        sub(/\r$/, "", line)
        text = text line "\n"
      }
    }
    /<item>/ { inItem = 1; buf = "" }
    inItem {
      buf = buf $0 "\n"
      if ($0 ~ /<\/item>/) {
        inItem = 0
        if (index(buf, "/" archive "\"") > 0) {
          sub(/[ \t]*<\/item>\n$/, "", buf)
          printf "%s            <whatsNew>%s</whatsNew>\n        </item>\n", buf, text
          hit++
        } else printf "%s", buf
      }
      next
    }
    { print }
    END { if (hit != 1) { printf "error: found %d appcast items for %s; expected 1\n", hit + 0, archive > "/dev/stderr"; exit 1 } }
  ' "$appcast" > "$out" || { rm -f "$out"; return 1; }
  cat "$out" > "$appcast"
  rm -f "$out"
}

case "${1:-}" in
  check) shift; check "$@" ;;
  inject) shift; inject "$@" ;;
  *) echo "usage: scripts/whats-new.sh check <file> | inject <appcast.xml> <archive> <file>" >&2; exit 2 ;;
esac
