#!/bin/bash
# Copyright 2026 Noah Qin
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0

# Keypress → glass, measured from inside Corta — no third-party tool, no screen
# capture. `RenderMetrics.keypressToPresent` takes
# the key event's timestamp and closes the sample in the drawable's
# presented handler, which fires when the frame carrying the child's echo
# is actually on screen (`MTLDrawable.presentedTime`), not when it was
# scheduled. 200 samples fill the ring and Corta prints one distribution
# line to the unified log; this script launches, drives or waits, and
# reads it back.
#
#   scripts/measure-keypress-latency.sh            # scripted: 320 synthetic keys
#   scripts/measure-keypress-latency.sh --manual   # you type ~300 characters
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
#
# CORTA_APP names the app to measure instead of the newest Release
# build — the Benchmark configuration's CortaDev.app, say, which has
# Release's optimisation and not the installed Corta's identity (D22).
# Measurement hooks such as CORTA_FRAME_LATENCY or CORTA_MAX_DRAWABLES
# pass through the environment to the app.
set -euo pipefail

mode=${1:-scripted}
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app=${CORTA_APP:-$("$repo_root/scripts/find-release-app.sh")}
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")
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
echo "frame latency: ${CORTA_FRAME_LATENCY:-default}"

start=$(date '+%Y-%m-%d %H:%M:%S')
CORTA_STAGE_DIR="$stage" CORTA_RESTORE_WINDOWS=0 CORTA_RENDER_METRICS=1 \
  "$app/Contents/MacOS/$executable" >/dev/null 2>&1 &
app_pid=$!
sleep 4
# By this launch's PID, not by name: another Corta may be running, and the
# keystrokes go to whatever is frontmost. Checked before any are sent.
frontmost=""
for _ in $(seq 1 10); do
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $app_pid) to true" \
    >/dev/null 2>&1 || true
  sleep 0.5
  frontmost=$(osascript -e 'tell application "System Events" to get unix id of first process whose frontmost is true' 2>/dev/null || echo "")
  [ "$frontmost" = "$app_pid" ] && break
done
if [ "$frontmost" != "$app_pid" ]; then
  echo "error: the launched app (pid $app_pid) never became frontmost; no keystrokes sent" >&2
  exit 1
fi

if [ "$mode" = "--manual" ]; then
  echo
  echo "Type about 300 ordinary characters into the Corta window (digits, or"
  echo "letters with an English input source — a CJK input method composes"
  echo "letters instead of sending them; no Return needed). Corta prints the"
  echo "distribution once 200 echoes have reached the screen; this script"
  echo "waits up to five minutes for it."
  deadline=$((SECONDS + 300))
else
  echo "posting 320 keystrokes about 150 ms apart (synthetic: HID stage excluded)"
  # A digit, not a letter: a CJK input method composes letters and sends
  # nothing to the shell until a candidate is chosen, but passes digits
  # straight through. Which key it is does not otherwise matter.
  # One osascript for the whole burst: a process per key spends more time
  # starting osascript than typing, and the spacing stops meaning anything.
  # 320, not 200: a keystroke whose echo shares a frame with the next one's
  # yields one sample, and the ring only prints when it is full — 230 left
  # it short on a login shell whose prompt redraws around each echo.
  # Stops if anything else comes to the front mid-run, rather than typing
  # into it, and says how many it sent. The check before each key adds its
  # own few milliseconds to the spacing, which is why it is "about".
  sent=$(osascript - "$app_pid" <<'APPLESCRIPT'
on run argv
  set target to (item 1 of argv) as integer
  set sent to 0
  tell application "System Events"
    repeat 320 times
      if (unix id of (first process whose frontmost is true)) is not target then exit repeat
      key code 18 -- "1"
      set sent to sent + 1
      delay 0.15
    end repeat
  end tell
  return sent
end run
APPLESCRIPT
)
  if [ "$sent" != 320 ]; then
    echo "error: another app came to the front after $sent keystrokes; typing stopped" >&2
    exit 1
  fi
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
