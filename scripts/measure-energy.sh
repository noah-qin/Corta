#!/bin/bash
# P10-side energy harness (B12, issue #39): drives the Release build through
# the energy-relevant scenarios and samples what the machine permits, writing
# a self-contained evidence log (environment header per PERFORMANCE.md §5.2,
# per-scenario p50/p95/p99/max distributions per §5.1 — never averages).
#
# Scenarios, in order:
#   1 idle                    — 1 window, frontmost, no output
#   2 occluded                — same window AXMinimized (app-baseline's method)
#   3 background-output flood — still minimized, `yes` into the pane's tty:
#                               the "occluded window must not render" case
#   4 multi-window            — 2 windows via SessionRestore (staged config,
#                               reverted on every exit path, same as
#                               measure-app-baseline.sh)
#   5 kitty-image             — a generated 64x64 PNG transmitted to the pane
#                               over the Kitty graphics protocol, then sampled
#                               static (decode is async; the settle covers it)
#   6 thermal / low-power     — NOT JUDGED: both are machine-wide state this
#                               harness must not change; they need a dedicated
#                               session on an idle machine.
#
# Sampling: `powermetrics --samplers tasks,cpu_power,gpu_power` when it can
# run (already root, or passwordless sudo). When it cannot, the script says
# so in the header and falls back to per-second `top` samples of the Corta
# process — CPU% plus a context-switch-delta proxy for wakeups (the true
# idle-wakeup counter is root-only). The fallback is labelled everywhere as
# what it is; no power number is invented.
#
# Usage: scripts/measure-energy.sh [results-file]
#   Default results file: dist/energy-<timestamp>.txt (dist/ is gitignored).
#   Do not use the machine while it runs: windows open and minimise on
#   screen, and background load skews every number.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app=$("$repo_root/scripts/find-release-app.sh")
mkdir -p "$repo_root/dist"
out="${1:-$repo_root/dist/energy-$(date '+%Y%m%d-%H%M%S').txt}"
exec > >(tee "$out") 2>&1

window_secs=${CORTA_ENERGY_WINDOW:-20}
# Every launch below runs against a throwaway stage (`CORTA_STAGE_DIR`,
# `AppPaths`): its own config file and Application Support, so the real
# `~/.config/corta/config` and the real window arrangement are never read,
# flipped or written by a measurement — the B16 test pass declined to run
# this script because it used to edit the real config in place.
stage=$(mktemp -d /tmp/corta-energy-stage.XXXXXX)
config_file="$stage/config"
state_dir="$stage/ApplicationSupport"
state_file="$state_dir/state.json"
mkdir -p "$state_dir"
printf 'restore-windows = false\nupdate-auto-check = false\nsuggest-applications-folder = false\n' > "$config_file"
app_pid=""

cleanup() {
  [ -n "$app_pid" ] && kill "$app_pid" 2>/dev/null || true
  rm -rf "$stage"
}
trap cleanup EXIT

# --- environment header: the rows PERFORMANCE.md §5.2 says a quoted run must fix
echo "== environment =="
echo "date: $(date '+%Y-%m-%d %H:%M:%S %z')"
echo "machine: $(sysctl -n hw.model) / $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores, $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion)); Xcode $(xcodebuild -version | head -1 | awk '{print $2}')"
echo "git: $(git -C "$repo_root" rev-parse --short HEAD)$(git -C "$repo_root" diff --quiet || echo ' +uncommitted (parallel team tree)')"
echo "power: $(pmset -g | grep -E 'sleep|lowpowermode|power_source' | tr '\n' '; ')"
echo "battery: $(pmset -g batt | sed -n 2p | sed 's/^ *//')"
echo "app: $app"
echo "results file: $out"
echo "window per scenario: ${window_secs}s at 1 sample/s"

power_sampler="unavailable"
power_note="powermetrics needs root and neither (a) running as root nor (b) passwordless sudo is available — power/wattage sampling is NOT RUN, recorded honestly as unavailable"
if [ "$(id -u)" -eq 0 ]; then
  power_sampler="powermetrics"; power_note=""
elif sudo -n true 2>/dev/null; then
  power_sampler="sudo-powermetrics"; power_note=""
fi
# The note is printed only when it is true — the first real run printed
# "NOT RUN" beside a sampler that was, in fact, running.
echo "sampler: $power_sampler ${power_note:+($power_note)}"
echo

launch() { # $2: "restore" = leave session restore on (multi-window scenario)
  if [ "${2:-}" = "restore" ]; then
    CORTA_STAGE_DIR="$stage" "$app/Contents/MacOS/Corta" >/dev/null 2>&1 &
  else
    CORTA_STAGE_DIR="$stage" CORTA_RESTORE_WINDOWS=0 "$app/Contents/MacOS/Corta" >/dev/null 2>&1 &
  fi
  app_pid=$!
}

bring_frontmost() { # a background-launched window throttles its display link
  for _ in $(seq 1 10); do
    osascript -e "tell application \"System Events\" to tell (first process whose unix id is $app_pid) to set frontmost to true" 2>/dev/null || true
    [ "$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null)" = "Corta" ] && return
    sleep 0.5
  done
}

set_minimized() { # true|false
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $app_pid) to set value of attribute \"AXMinimized\" of window 1 to $1" 2>/dev/null || true
}

window_count() {
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $app_pid) to count windows" 2>/dev/null || echo -1
}

pane_ttys() {
  pgrep -P "$app_pid" | while read -r p; do ps -o tty= -p "$p" | tr -d ' '; done | grep -v '^??$' || true
}

distributions() { # label, file of one number per line
  python3 - "$1" "$2" <<'EOF'
import sys
label, path = sys.argv[1], sys.argv[2]
values = sorted(float(line) for line in open(path) if line.strip())
if not values:
    print(f"{label}: n=0 (no samples)")
    raise SystemExit
n = len(values)
def pct(p):
    return values[min(n - 1, int(n * p))]
print(f"{label}: n={n} p50={pct(0.50):.2f} p95={pct(0.95):.2f} p99={pct(0.99):.2f} max={values[-1]:.2f}")
EOF
}

sample_window() { # label — samples the current app for $window_secs, prints distributions
  local label=$1
  if [ "$power_sampler" != "unavailable" ]; then
    local prefix=""
    [ "$power_sampler" = "sudo-powermetrics" ] && prefix="sudo -n"
    local raw
    raw=$(mktemp /tmp/corta-energy.XXXXXX)
    $prefix powermetrics --samplers tasks,cpu_power,gpu_power --show-process-energy \
      -n "$window_secs" -i 1000 > "$raw" 2>/dev/null || true
    grep -E 'Combined Power' "$raw" | sed -E 's/.*: *([0-9.]+) mW/\1/' > "$raw.combined" || true
    distributions "combined CPU+GPU+ANE power (mW, MACHINE-WIDE — includes every process)" "$raw.combined"
    echo "   Corta rows from the tasks sampler (first 5, verbatim — per-row field layout is OS-version-dependent):"
    grep -E '^Corta' "$raw" | head -5 | sed 's/^/   /' || echo "   (no Corta rows captured)"
    rm -f "$raw" "$raw.combined"
  else
    # Degraded path: per-second top samples of just the Corta process.
    # CPU% is per-window once the first (lifetime-average) sample is dropped;
    # CSW is cumulative, so only its delta over the window is meaningful —
    # it is a scheduling-activity proxy, NOT the root-only idle-wakeup counter.
    local raw
    raw=$(mktemp /tmp/corta-energy.XXXXXX)
    top -l $((window_secs + 1)) -s 1 -pid "$app_pid" -stats pid,cpu,threads,csw -n 1 2>/dev/null \
      | grep -E "^${app_pid} " | awk '{print $2, $4}' > "$raw" || true
    tail -n +2 "$raw" | awk '{print $1}' > "$raw.cpu" || true
    distributions "cpu% (top, per-second)" "$raw.cpu"
    python3 - "$raw" "$window_secs" <<'EOF'
import sys
rows = [l.split() for l in open(sys.argv[1]) if l.strip()]
secs = float(sys.argv[2])
if len(rows) >= 2:
    delta = int(rows[-1][1]) - int(rows[0][1])
    print(f"context switches: {delta} over {secs:.0f}s ({delta / secs:.1f}/s — wakeup proxy; true idle-wakeup counter is root-only, unavailable)")
else:
    print("context switches: n<2 (no samples)")
EOF
    local threads
    threads=$(ps -M -p "$app_pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    echo "threads at end of window: $threads"
    rm -f "$raw" "$raw.cpu"
  fi
}

kill_app() {
  [ -n "$app_pid" ] && kill "$app_pid" 2>/dev/null || true
  wait "$app_pid" 2>/dev/null || true
  app_pid=""
  sleep 2
}

# ================= scenarios 1-3: one window — idle, occluded, flood ========
echo "== scenario 1/5: idle (1 window, frontmost, no output, ${window_secs}s) =="
launch
sleep 3
if [ "$(window_count)" -lt 1 ]; then echo "ABORT: no window"; exit 1; fi
bring_frontmost
sleep 2
sample_window "idle"
echo

echo "== scenario 2/5: occluded (AXMinimized, ${window_secs}s) =="
set_minimized true
sleep 3
echo "   minimized state: $(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $app_pid) to get value of attribute \"AXMinimized\" of window 1" 2>/dev/null || echo unknown)"
sample_window "occluded"
set_minimized false
sleep 2
echo

echo "== scenario 3/5: background-output flood (occluded + yes into the pane tty, ${window_secs}s) =="
set_minimized true
sleep 3
flood_pid=""
for t in $(pane_ttys); do yes > "/dev/$t" 2>/dev/null & flood_pid=$!; done
sample_window "background-output-flood"
[ -n "$flood_pid" ] && { kill "$flood_pid" 2>/dev/null; wait "$flood_pid" 2>/dev/null; } || true
set_minimized false
sleep 2
kill_app
echo

# ================= scenario 4: two windows via SessionRestore ===============
echo "== scenario 4/5: multi-window (2 windows, both visible, ${window_secs}s) =="
sed -i '' 's/^restore-windows = false/restore-windows = true/' "$config_file"
if ! grep -q '^restore-windows = true' "$config_file"; then
  echo "config has no 'restore-windows = false' line to flip — scenario NOT RUN"
else
  mkdir -p "$state_dir"
  cat > "$state_file" <<'EOF'
[{"frame":{"x":60,"y":100,"width":900,"height":600},"layout":{"pane":{"directory":null}}},
 {"frame":{"x":1000,"y":100,"width":900,"height":600},"layout":{"pane":{"directory":null}}}]
EOF
  launch "" restore
  sleep 5
  echo "   windows after restore: $(window_count) (2 = both restored; anything else and the numbers are not a 2-window run)"
  bring_frontmost
  sleep 2
  sample_window "multi-window-2"
  kill_app
fi
sed -i '' 's/^restore-windows = true/restore-windows = false/' "$config_file"
rm -f "$state_file"
echo

# ================= scenario 5: kitty image, static ==========================
echo "== scenario 5/5: kitty-image (64x64 PNG placed at the cursor, then static, ${window_secs}s) =="
png_b64=$(python3 - <<'EOF'
import struct, zlib, base64
w = h = 64
def chunk(kind, payload):
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))
ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
raw = b"".join(
    b"\x00" + b"".join(bytes([(x * 4) % 256, (y * 4) % 256, 192, 255]) for x in range(w))
    for y in range(h)
)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
print(base64.b64encode(png).decode())
EOF
)
launch
sleep 3
bring_frontmost
sleep 2
tty=$(pane_ttys | head -1)
if [ -z "$tty" ]; then
  echo "   no pane tty found — scenario NOT RUN"
else
  # q=2: suppress the protocol's acknowledgement, which would otherwise
  # land on the shell's input as garbage bytes. a=T: transmit and place.
  printf '\033_Gq=2,a=T,f=100,s=64,v=64;%s\033\\' "$png_b64" > "/dev/$tty"
  sleep 4 # the decode is async (P05); onImagesReady schedules the frame
  sample_window "kitty-image-static"
fi
kill_app
echo

# ================= scenario 6: what this harness cannot force ===============
echo "== scenario 6/5: thermal pressure / Low Power Mode =="
echo "   NOT JUDGED: both are machine-wide state a measurement script must not"
echo "   change (same rule measure-app-baseline.sh follows). They need a"
echo "   dedicated session on an idle machine."
echo
echo "== done =="
trap - EXIT
