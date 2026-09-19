#!/bin/bash
# Keypress → glass, measured from inside Corta — no third-party tool, no screen
# capture. `RenderMetrics.keypressToPresent` takes
# the key event's timestamp and closes the sample in the drawable's
# presented handler, which fires when the frame carrying the child's echo
# is actually on screen (`MTLDrawable.presentedTime`), not when it was
# scheduled. 200 samples fill the ring and Corta prints one distribution
# line to the unified log; this script launches, drives or waits, and
# reads it back.
#
#   scripts/measure-keypress-latency.sh            # scripted: 200 synthetic keys
#   scripts/measure-keypress-latency.sh --manual   # you type 200 characters
#
# Scripted keys are posted by System Events, so their timestamp is minted
# at posting: the USB/Bluetooth HID stage (typically 1–8 ms) is *not* in
# the number, and the result is a lower bound on what a finger sees.
# `--manual` includes it — type 200 ordinary characters at a shell
# prompt (no Return needed) — and is the number to quote beside a
# screen-capture figure. Both are stated as which they are.
#
# The fixed environment of PERFORMANCE.md §5.2 applies: Release build,
# built-in display, mains, nothing else in front. Runs against a
# throwaway CORTA_STAGE_DIR; the real config is never read.
set -euo pipefail

mode=${1:-scripted}
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app=$("$repo_root/scripts/find-release-app.sh")
stage=$(mktemp -d /tmp/corta-keypress-stage.XXXXXX)
printf 'restore-windows = false\nupdate-auto-check = false\nsuggest-applications-folder = false\n' > "$stage/config"
app_pid=""
cleanup() {
  if [ -n "$app_pid" ]; then kill "$app_pid" 2>/dev/null; wait "$app_pid" 2>/dev/null; fi
  rm -rf "$stage"
}
trap cleanup EXIT

echo "== keypress -> glass, $(date '+%Y-%m-%d %H:%M:%S %z') =="
echo "machine: $(sysctl -n hw.model) / $(sysctl -n machdep.cpu.brand_string); macOS $(sw_vers -productVersion)"
echo "power: $(pmset -g batt | head -1 | sed 's/Now drawing from //')"
echo "app: $app"
echo "mode: $mode"

start=$(date '+%Y-%m-%d %H:%M:%S')
CORTA_STAGE_DIR="$stage" CORTA_RESTORE_WINDOWS=0 CORTA_RENDER_METRICS=1 \
  "$app/Contents/MacOS/Corta" >/dev/null 2>&1 &
app_pid=$!
sleep 4
osascript -e 'tell application "System Events" to tell process "Corta" to set frontmost to true' >/dev/null
sleep 1

if [ "$mode" = "--manual" ]; then
  echo
  echo "Type about 230 ordinary characters into the Corta window (letters are"
  echo "fine, no Return needed). Corta prints the distribution once 200 echoes"
  echo "have reached the screen; this script waits up to five minutes for it."
  deadline=$((SECONDS + 300))
else
  echo "posting 230 keystrokes at 150 ms spacing (synthetic: HID stage excluded)"
  # One osascript for the whole burst: a process per key spends more time
  # starting osascript than typing, and the spacing stops meaning anything.
  # 230, not 200: a keystroke whose echo shares a frame with the next one's
  # yields one sample, and the ring only prints when it is full.
  osascript -e 'tell application "System Events"
    repeat 230 times
      key code 0
      delay 0.15
    end repeat
  end tell' >/dev/null  # key code 0 is "a"
  deadline=$((SECONDS + 30))
fi

result=""
while [ $SECONDS -lt $deadline ]; do
  result=$(/usr/bin/log show --start "$start" --style compact \
    --predicate 'subsystem == "dev.noahqin.Corta" AND category == "render-metrics"' 2>/dev/null \
    | grep -E 'keypressToPresent:' | tail -1 || true)
  [ -n "$result" ] && break
  sleep 3
done

echo
if [ -n "$result" ]; then
  echo "$result" | sed -E 's/.*keypressToPresent:/keypressToPresent:/'
  echo "(n samples of key event -> drawable presented, in ms; ${mode} run)"
else
  echo "no keypressToPresent dump within the wait — fewer than 200 echoes reached the screen"
fi
