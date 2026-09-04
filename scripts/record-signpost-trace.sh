#!/bin/bash
# M8.19: records an os_signpost trace of a real, focused typing session —
# the thing both previous attempts couldn't get. Launching Corta *from*
# Instruments' Record button never handed the new process window focus,
# so the keystrokes typed right after launch landed elsewhere and every
# recording showed zero keyDown/output events (PERFORMANCE.md §5.3).
#
# The fix: launch Corta normally first (it gets focus the way it always
# does), then attach a trace to the already-running, already-focused
# process instead of launching through Instruments at all.
#
# Usage: scripts/record-signpost-trace.sh [output.trace]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app=$("$repo_root/scripts/find-release-app.sh")
# .build/, not ~/Desktop: Terminal needs a one-time TCC grant (System
# Settings > Privacy & Security > Files and Folders) to write to Desktop/
# Documents/Downloads, and xctrace fails outright without it ("File path
# is not readable"). .build/ is already inside what Terminal can write to
# a project directory it's running in, and is already gitignored.
mkdir -p "$repo_root/.build/traces"
output="${1:-$repo_root/.build/traces/corta-signpost-$(date +%Y%m%d-%H%M%S).trace}"

echo "==> Using $app"
echo "==> Launching Corta normally, so it gets window focus"
CORTA_RESTORE_WINDOWS=0 "$app/Contents/MacOS/Corta" &
app_pid=$!
sleep 2

# A silently-swallowed `activate` was the actual root cause the last time
# this looked like a focus problem: `2>/dev/null || true` hid the fact
# that Corta never actually became frontmost, so typing kept landing in
# whatever window (very plausibly this very terminal) already had focus.
# This blocks — with visible, honest status — until System Events itself
# confirms Corta is frontmost, targeted by this run's own PID so a stray
# second instance can't be what gets activated instead.
echo "==> Waiting for Corta (pid $app_pid) to actually become frontmost..."
frontmost=""
for _ in $(seq 1 15); do
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $app_pid) to set frontmost to true" \
    2>/dev/null || true
  frontmost=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null || echo "")
  if [ "$frontmost" = "Corta" ]; then
    break
  fi
  sleep 0.5
done
if [ "$frontmost" != "Corta" ]; then
  echo "!! Corta never became frontmost (System Events reports '$frontmost' instead)." >&2
  echo "!! Click the Corta window yourself now, then press Enter here to proceed anyway," >&2
  echo "!! or Ctrl-C to abort." >&2
  read -r _
else
  echo "==> Confirmed: Corta is frontmost."
fi

echo "==> Attaching an os_signpost trace to the running process"
echo "    Output: $output"
echo
echo "    The moment you see 'Recording...' below, DO NOT come back to this"
echo "    terminal window. Go straight to the Corta window (already"
echo "    frontmost) and type an ordinary sentence at a natural pace — real"
echo "    keystrokes, real gaps. Only come back here, a few seconds after"
echo "    your last keystroke, to press Ctrl-C and stop the recording."
echo

# `--template 'os_signpost'` (what PERFORMANCE.md §5.3 originally
# documented) doesn't resolve on this Xcode version — `xctrace list
# templates` has no such entry. `os_signpost` is an *instrument*, not a
# template (`xctrace list instruments` does list it), so `--instrument`
# is the correct flag here.
xcrun xctrace record --attach Corta --instrument 'os_signpost' --output "$output"

echo
echo "==> Saved to $output"
echo "==> Open it in Instruments and check the keyDown lane is non-empty"
echo "    BEFORE reading anything else from it — that's the check the"
echo "    previous two attempts failed. If it's empty, Corta likely"
echo "    wasn't frontmost when typing started; re-run and check activation."
echo
echo "    kill the launched Corta:"
echo "    kill $app_pid"
