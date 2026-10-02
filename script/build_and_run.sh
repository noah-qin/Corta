#!/usr/bin/env bash
# Build and run only this checkout's development application.
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_MODE="${1:-run}"
TASK_APP="$TASK_ROOT/.build/ui/Build/Products/Debug/CortaDev.app"
TASK_BINARY="$TASK_APP/Contents/MacOS/CortaDev"
case "$TASK_MODE" in
  run|--debug|--logs|--telemetry|--verify|--sftp-preview) ;;
  *) echo "usage: $0 [--debug|--logs|--telemetry|--verify|--sftp-preview]" >&2; exit 2 ;;
esac
# Match the executable path, so another checkout or installed app stays open.
while read -r task_pid; do
  [[ -n "$task_pid" ]] && kill -TERM "$task_pid"
done < <(pgrep -f "^$TASK_BINARY([[:space:]]|$)" || true)
xcodebuild -project "$TASK_ROOT/Corta.xcodeproj" -scheme 'Corta (Dev)' \
  -configuration Debug -derivedDataPath "$TASK_ROOT/.build/ui" build
case "$TASK_MODE" in
  --debug) exec lldb -- "$TASK_BINARY" ;;
  --sftp-preview) /usr/bin/open -n "$TASK_APP" --args --sftp-preview ;;
  *) /usr/bin/open -n "$TASK_APP" ;;
esac
case "$TASK_MODE" in
  --verify) sleep 2; pgrep -f "^$TASK_BINARY([[:space:]]|$)" ;;
  --logs) exec /usr/bin/log stream --info --style compact --predicate 'process == "CortaDev"' ;;
  --telemetry) exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "dev.noahqin.Corta.dev"' ;;
esac
