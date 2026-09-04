#!/bin/bash
# M8.18: launches the Release build twice, back to back — once at the
# default maximumDrawableCount (3), once at CORTA_MAX_DRAWABLES=2 — so the
# only variable between the two Typometer runs you do against them is that
# one launch environment flag (PERFORMANCE.md §5.4).
#
# This script only launches; it does not run Typometer for you (Typometer
# has to watch the physical screen, which nothing scripted can stand in
# for). Between the two launches it pauses and tells you which run to do.
#
# Usage: scripts/measure-drawable-ab.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app=$("$repo_root/scripts/find-release-app.sh")
echo "==> Using $app"
echo "==> Typometer settings for both runs: 200 chars / 150ms delay / 50ms period /"
echo "    1000ms length / synchronous mode, no intermediate pauses (PERFORMANCE.md §5.5)."
echo

run_one() {
  local label="$1"; shift
  echo "=== Run $label ==="
  echo "Launching..."
  "$@" &
  local pid=$!
  echo "Corta is running (pid $pid). Bring it frontmost, run Typometer's $label pass now."
  echo "Press Enter here when that Typometer run is done (this will quit Corta)."
  read -r _
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo
}

run_one "A (default, maximumDrawableCount=3)" \
  env CORTA_RESTORE_WINDOWS=0 "$app/Contents/MacOS/Corta"

run_one "B (maximumDrawableCount=2)" \
  env CORTA_RESTORE_WINDOWS=0 CORTA_MAX_DRAWABLES=2 "$app/Contents/MacOS/Corta"

echo "==> Both runs done. Record all four Typometer numbers (min/avg/max/SD) for"
echo "    each in docs/PERFORMANCE.md §5.4, and check ROADMAP.md's M8.18 box."
