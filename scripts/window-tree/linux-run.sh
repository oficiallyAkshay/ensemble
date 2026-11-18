#!/bin/bash
# Runs the reader on Linux inside a virtual display and a private session bus with the accessibility bus started.
# Usage: scripts/window-tree/linux-run.sh <output folder>
set -u
cd "$(dirname "$0")/../.."
out=${1:?output folder}
export OUT="$out"
export SHOT_CMD="import -window root $out/screenshot.png"
export GNOME_ACCESSIBILITY=1
exec xvfb-run -a -s "-screen 0 1280x800x24" dbus-run-session -- bash -c '
  /usr/libexec/at-spi-bus-launcher --launch-immediately &
  sleep 2
  python scripts/window-tree/read_tree.py
'
