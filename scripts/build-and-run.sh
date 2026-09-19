#!/bin/bash
# Isolated developer launch: never reads or writes the user's Corta config.
set -euo pipefail
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${CORTA_BUILD_DIR:-$root_dir/.build/run}"
mkdir -p "$build_dir"
build_dir="$(cd "$build_dir" && pwd -P)"
stage_dir="$build_dir/launch-stage"
mode="${1:-run}"
case "$mode" in run|--verify|--debug|--logs|--telemetry) ;; *) echo "Usage: $0 [--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;; esac
mkdir -p "$stage_dir"
app_binary="$build_dir/Build/Products/Debug/Corta.app/Contents/MacOS/Corta"
# Stop only an earlier launch of this build, never another installed Corta.
if [[ -f "$stage_dir/pid" ]]; then
    previous_pid=$(cat "$stage_dir/pid")
    if [[ "$(ps -p "$previous_pid" -o comm= 2>/dev/null || true)" == "$app_binary" ]]; then
        kill "$previous_pid"
    fi
fi
xcodebuild -project "$root_dir/Corta.xcodeproj" -scheme Corta -configuration Debug \
    -derivedDataPath "$build_dir" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= build -quiet
if [[ ! -f "$stage_dir/config" ]]; then
    cat > "$stage_dir/config" <<'CONFIG'
suggest-applications-folder = false
secure-keyboard-entry = false
quick-terminal = false
restore-windows = false
CONFIG
fi
export CORTA_STAGE_DIR="$stage_dir" CORTA_RESTORE_WINDOWS=0
export SHELL=/bin/sh
if [[ "$mode" == --debug ]]; then exec lldb -- "$app_binary"; fi
/usr/bin/open -n "$build_dir/Build/Products/Debug/Corta.app" \
    --env "CORTA_STAGE_DIR=$stage_dir" --env CORTA_RESTORE_WINDOWS=0 --env SHELL=/bin/sh \
    --stdout "$stage_dir/app.log" --stderr "$stage_dir/app.log"
sleep 1
app_pid=$(pgrep -f "^$app_binary$" | tail -1)
echo "$app_pid" > "$stage_dir/pid"
case "$mode" in
    --verify) sleep 2; kill -0 "$app_pid" ;;
    --logs) exec /usr/bin/log stream --info --predicate 'process == "Corta"' ;;
    --telemetry) exec /usr/bin/log stream --info --predicate 'subsystem == "dev.noahqin.Corta"' ;;
esac
printf 'Launched %s (PID %s)\n' "$app_binary" "$app_pid"
