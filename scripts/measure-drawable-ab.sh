#!/bin/bash
# M8.18: the same Release build measured twice, back to back — once at the
# default maximumDrawableCount (3), once at CORTA_MAX_DRAWABLES=2 — so the
# only variable between the two runs is that one launch environment flag
# (PERFORMANCE.md §5.4). Each run is scripts/measure-keypress-latency.sh,
# which launches, drives 230 synthetic keystrokes and prints the in-app
# keypress-to-glass distribution (§5.7); the environment flag is inherited
# by the launch inside it. Pass --manual to type the samples yourself in
# both runs (HID stage included).
#
# Usage: scripts/measure-drawable-ab.sh [--manual]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode=${1:-}

echo "=== Run A (default, maximumDrawableCount=3) ==="
"$repo_root/scripts/measure-keypress-latency.sh" $mode
echo
echo "=== Run B (maximumDrawableCount=2) ==="
CORTA_MAX_DRAWABLES=2 "$repo_root/scripts/measure-keypress-latency.sh" $mode
echo
echo "==> Compare the two keypressToPresent lines; a difference inside either"
echo "    run's p50–p95 spread is noise (PERFORMANCE.md §5.4)."
