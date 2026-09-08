#!/bin/bash
# P07/P09/P10/P11 app-side baseline: drives the Release build through the
# phases the core-side `corta-bench` cannot see — real window, real display
# link, real AppKit. Kept separate from corta-bench because everything here
# needs an on-screen window; the core package numbers are headless and belong
# in corta-bench.
#
# Driving constraints discovered while building this (2026-09-06):
#   * System Events `keystroke`/`key code` do NOT reach Corta from this
#     harness (synthetic key events are dropped somewhere between System
#     Events and TerminalView — an `exit` typed this way never reaches the
#     shell). Floods are therefore driven by writing to the pane's PTY
#     *slave* (/dev/ttysNNN of the child shell), which needs no UI input at
#     all and exercises the same reader -> parse -> render path.
#   * AX attribute manipulation DOES work (AXMinimized set/get verified), so
#     occlusion and window close use the AX API directly.
#   * Splits cannot be keyboard-driven, so multi-pane windows are built via
#     SessionRestore: the script temporarily flips `restore-windows` to true
#     in ~/.config/corta/config, writes a 2- or 4-pane state.json, launches,
#     then reverts the config. The original config is restored byte-for-byte
#     on every exit path; state.json is consumed by the restore itself.
#
# Phases, in order:
#   A launch   — P09: process start -> first window on screen, 1 "cold-ish"
#                (first launch of this binary in this session — dyld/page
#                caches are warm; a true cold boot is not scriptable without
#                sudo purge) + 5 warm launches. PTY+shell startup below the
#                app is corta-bench's spawn decomposition; add them.
#   B 1-pane   — P10 idle (20 s of samples) -> P11 flood (seq into the pane's
#                tty, CORTA_RENDER_METRICS=1 rings collected from the unified
#                log) -> P10 occluded (AXMinimized, 20 s) -> post-close
#                recovery (AX close button; the app keeps running).
#   C 2-pane   — P07: restore a 2-pane layout, settle sample, flood both
#                panes, frame metrics.
#   D 4-pane   — same with a 4-pane layout.
#
# Sleep/wake and low-power-mode rows of P10 are NOT covered on purpose: both
# change machine-wide state other people and processes depend on; they need
# a dedicated session on an idle machine.
#
# Usage: scripts/measure-app-baseline.sh
#   Do not use the machine while it runs: windows open, minimise and close
#   on screen. Output is a self-contained evidence log on stdout.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app=$("$repo_root/scripts/find-release-app.sh")
config_file="$HOME/.config/corta/config"
state_dir="$HOME/Library/Application Support/Corta"
state_file="$state_dir/state.json"
config_backup=""
state_backup=""

cleanup() {
  [ -n "$config_backup" ] && cp "$config_backup" "$config_file" 2>/dev/null || true
  if [ -n "$state_backup" ]; then
    cp "$state_backup" "$state_file" 2>/dev/null || true
  else
    rm -f "$state_file" 2>/dev/null || true
  fi
  [ -n "${app_pid:-}" ] && kill "$app_pid" 2>/dev/null || true
}
trap cleanup EXIT

now_ns() { python3 -c 'import time; print(time.time_ns())'; }
elapsed_ms() { python3 -c "print(f'{($2 - $1) / 1e6:.1f}')"; }

# --- environment header: the rows PERFORMANCE.md §5.2 says a quoted run must fix
echo "== environment =="
echo "date: $(date '+%Y-%m-%d %H:%M:%S %z')"
echo "machine: $(sysctl -n hw.model) / $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores, $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion)); Xcode $(xcodebuild -version | head -1 | awk '{print $2}')"
echo "git: $(git -C "$repo_root" rev-parse --short HEAD)$(git -C "$repo_root" diff --quiet || echo ' +uncommitted (parallel team tree)')"
echo "power: $(pmset -g | grep -E 'sleep|lowpowermode|power_source' | tr '\n' '; ')"
echo "battery: $(pmset -g batt | sed -n 2p | sed 's/^ *//')"
python3 - <<'EOF'
import subprocess
out = subprocess.run(["system_profiler", "SPDisplaysDataType"], capture_output=True, text=True).stdout
for line in out.splitlines():
    s = line.strip()
    if s.startswith(("Display Type:", "Resolution:", "UI Looks Like:", "Main Display:", "Mirror:", "Online:", "Rotation:", "Automatically Adjust", "True Tone:")):
        print("display:", s)
EOF
echo "display mode (CoreGraphics): $(swift -e 'import CoreGraphics; let m = CGDisplayCopyDisplayMode(CGMainDisplayID()); print("\(m!.width)x\(m!.height)@\(m!.pixelWidth / max(m!.width,1))x, refresh \(m!.refreshRate) Hz")' 2>/dev/null)"
echo "app: $app"
echo

launch() { # $2: "metrics" = render metrics, restore off; "restore-metrics" = metrics, restore left on
  case "${2:-}" in
    metrics)
      CORTA_RESTORE_WINDOWS=0 CORTA_RENDER_METRICS=1 "$app/Contents/MacOS/Corta" >/dev/null 2>&1 & ;;
    restore-metrics)
      CORTA_RENDER_METRICS=1 "$app/Contents/MacOS/Corta" >/dev/null 2>&1 & ;;
    *)
      CORTA_RESTORE_WINDOWS=0 "$app/Contents/MacOS/Corta" >/dev/null 2>&1 & ;;
  esac
  app_pid=$!
}

wait_for_window() { # pid -> echoes ms from $1 ns timestamp, or empty
  local t0=$1 deadline
  deadline=$(( $(now_ns) + 15000000000 ))
  while [ "$(now_ns)" -lt "$deadline" ]; do
    wins=$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $app_pid) to count windows" 2>/dev/null || echo 0)
    if [ "${wins:-0}" -ge 1 ] 2>/dev/null; then
      elapsed_ms "$t0" "$(now_ns)"
      return
    fi
  done
}

sample() { # label
  local label=$1 row threads fds
  row=$(ps -o %cpu=,rss= -p "$app_pid" 2>/dev/null) || return 0
  threads=$(ps -M -p "$app_pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
  fds=$(lsof -p "$app_pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
  echo "sample[$label]: $(date '+%H:%M:%S') cpu=$(echo "$row" | awk '{print $1}')% rss=$(echo "$row" | awk '{printf "%.1f", $2/1024}')MB threads=$threads fds=$fds children=$(pgrep -P "$app_pid" 2>/dev/null | wc -l | tr -d ' ')"
}

cpu_seconds() { # pid lifetime CPU in seconds (ps %cpu is a *lifetime average* and useless for burst phases)
  ps -o time= -p "$app_pid" 2>/dev/null | python3 -c '
import sys
raw = sys.stdin.read().strip()
days = 0
if "-" in raw:
    d, raw = raw.split("-", 1); days = int(d)
parts = [float(x) for x in raw.split(":")]
secs = 0.0
for p in parts: secs = secs * 60 + p
print(days * 86400 + secs)'
}

pane_ttys() { # lists the tty of each direct child shell
  pgrep -P "$app_pid" | while read -r p; do ps -o tty= -p "$p" | tr -d ' '; done | grep -v '^??$' || true
}

flood_panes() { # seconds — `yes`, not `seq`: a bounded burst drains at core
  # feed rate (~130 MB/s) in milliseconds and only damages a handful of
  # frames; a sustained flood keeps the display link un-parked for the
  # whole window, which is what the 600-sample render-metrics rings need.
  local secs=$1 t flood_pids=()
  local cpu_before
  cpu_before=$(cpu_seconds)
  for t in $(pane_ttys); do
    yes > "/dev/$t" 2>/dev/null &
    flood_pids+=($!)
  done
  sleep "$secs"
  for fp in "${flood_pids[@]}"; do kill "$fp" 2>/dev/null || true; done
  wait "${flood_pids[@]}" 2>/dev/null || true
  local cpu_after
  cpu_after=$(cpu_seconds)
  python3 -c "print(f'   app CPU during flood window: {($cpu_after - $cpu_before) / $secs * 100:.1f}% (cputime delta over ${secs}s)')"
}

collect_metrics() { # label start-timestamp("YYYY-MM-DD HH:MM:SS")
  echo "-- render-metrics log, phase: $1"
  sleep 2
  log show --start "$2" --style compact \
    --predicate 'subsystem == "dev.noahqin.Corta" AND category == "render-metrics"' 2>/dev/null \
    | grep -E '(cpuFrame|gpu|drawableWait):' | tail -40 || echo "   (no render-metrics dumps — rings may not have filled)"
}

set_minimized() { # true|false
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $app_pid) to set value of attribute \"AXMinimized\" of window 1 to $1" 2>/dev/null || true
}

window_count() {
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $app_pid) to count windows" 2>/dev/null || echo -1
}

# ================= Phase A: P09 launch timing =================
echo "== phase A: launch timing (P09), 1 cold-ish + 5 warm; app side = process start -> first window =="
for i in 1 2 3 4 5 6; do
  t0=$(now_ns)
  launch
  window_ms=$(wait_for_window "$t0")
  label=$([ "$i" -eq 1 ] && echo "cold-ish" || echo "warm")
  echo "launch[$i $label]: start->first-window ${window_ms:-TIMEOUT} ms (poll granularity ~60 ms)"
  kill "$app_pid" 2>/dev/null || true
  wait "$app_pid" 2>/dev/null || true
  sleep 2
done
unset app_pid
echo

# ============ Phase B: 1 pane — idle, flood, occluded, close ============
echo "== phase B: 1 pane (P10 idle, P11 frame metrics, P10 occluded, post-close) =="
launch "" metrics
sleep 2
if [ "$(window_count)" -lt 1 ]; then echo "ABORT: no window"; exit 1; fi
# The display link throttles for a window that never comes to the front —
# a background launch renders nothing and the 600-sample rings never fill.
for _ in $(seq 1 10); do
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $app_pid) to set frontmost to true" 2>/dev/null || true
  [ "$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null)" = "Corta" ] && break
  sleep 0.5
done
echo "Corta pid $app_pid up (1 pane), frontmost: $(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null)"
sleep 5

echo "-- idle sampling (20 s)"
idle_cpu_before=$(cpu_seconds); idle_start=$(now_ns)
for _ in $(seq 1 10); do sample "idle-1p"; sleep 2; done
idle_cpu_after=$(cpu_seconds); idle_end=$(now_ns)
python3 -c "print(f'   idle avg CPU (cputime delta): {($idle_cpu_after - $idle_cpu_before) / (($idle_end - $idle_start) / 1e9) * 100:.2f}%')"

phase_start=$(date '+%Y-%m-%d %H:%M:%S')
echo "-- flood, 1 pane (20 s — a 600-frame ring at 60 Hz fills in 10 s; 12 s proved marginal)"
flood_panes 20
sample "during-flood-1p"
collect_metrics "flood-1-pane" "$phase_start"
sleep 5
sample "post-flood-1p"

echo "-- occluded (AXMinimized), 20 s"
set_minimized true
sleep 3
echo "   minimized state: $(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $app_pid) to get value of attribute \"AXMinimized\" of window 1" 2>/dev/null || echo unknown)"
for _ in $(seq 1 9); do sample "occluded-1p"; sleep 2; done
set_minimized false
sleep 2
sample "restored-1p"

echo "-- post-close recovery: AX close button on the window; app keeps running"
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $app_pid) to perform action \"AXPress\" of (first button of window 1 whose subrole is \"AXCloseButton\")" 2>/dev/null || true
sleep 5
echo "   windows after close: $(window_count) (0 = closed; 1 = a confirm-close sheet or a refusal)"
sample "post-window-close"
kill "$app_pid" 2>/dev/null || true
wait "$app_pid" 2>/dev/null || true
unset app_pid
sleep 2
echo

# ============ Phases C/D: 2- and 4-pane via SessionRestore ============
write_layout() { # pane count -> state.json
  local n=$1
  mkdir -p "$state_dir"
  case $n in
    2) cat > "$state_file" <<'EOF'
[{"frame":{"x":100,"y":100,"width":1200,"height":800},
  "layout":{"split":{"vertical":true,"position":0.5,
    "first":{"pane":{"directory":null}},"second":{"pane":{"directory":null}}}}}]
EOF
      ;;
    4) cat > "$state_file" <<'EOF'
[{"frame":{"x":100,"y":100,"width":1200,"height":800},
  "layout":{"split":{"vertical":true,"position":0.5,
    "first":{"split":{"vertical":false,"position":0.5,"first":{"pane":{"directory":null}},"second":{"pane":{"directory":null}}}},
    "second":{"split":{"vertical":false,"position":0.5,"first":{"pane":{"directory":null}},"second":{"pane":{"directory":null}}}}}}}]
EOF
      ;;
  esac
}

echo "== phases C/D: multi-pane (P07) via SessionRestore =="
cp "$config_file" /tmp/corta-config-backup.$$ && config_backup=/tmp/corta-config-backup.$$
[ -f "$state_file" ] && cp "$state_file" /tmp/corta-state-backup.$$ && state_backup=/tmp/corta-state-backup.$$
sed -i '' 's/^restore-windows = false/restore-windows = true/' "$config_file"
if ! grep -q '^restore-windows = true' "$config_file"; then
  echo "ABORT: could not flip restore-windows in config"; exit 1
fi
echo "config restore-windows flipped to true (backup at $config_backup)"

for n in 2 4; do
  write_layout "$n"
  t0=$(now_ns)
  launch "" restore-metrics
  window_ms=$(wait_for_window "$t0")
  sleep 4
  kids=$(pgrep -P "$app_pid" 2>/dev/null | wc -l | tr -d ' ')
  echo "restore[$n panes]: start->first-window ${window_ms:-TIMEOUT} ms, children=$kids ($([ "$kids" -eq "$n" ] && echo OK || echo MISMATCH — restore failed, numbers are not $n-pane))"
  sample "$n-panes-settled"

  phase_start=$(date '+%Y-%m-%d %H:%M:%S')
  echo "-- flood, $n panes (20 s)"
  flood_panes 20
  sample "during-flood-${n}p"
  collect_metrics "flood-$n-panes" "$phase_start"

  kill "$app_pid" 2>/dev/null || true
  wait "$app_pid" 2>/dev/null || true
  unset app_pid
  sleep 2
done

# Restore the user's config (also done by the trap; do it now so a later
# failure cannot leave it flipped).
cp "$config_backup" "$config_file"; config_backup=""
rm -f "$state_file"
echo "config restored; state.json cleaned."
echo "== done =="
trap - EXIT
