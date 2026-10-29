#!/usr/bin/env bash
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

# Build and run only this checkout's development application.
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_MODE="${1:-run}"
TASK_APP="$TASK_ROOT/.build/ui/Build/Products/Debug/CortaDev.app"
TASK_BINARY="$TASK_APP/Contents/MacOS/CortaDev"
# pgrep uses an extended regular expression; match the checkout literally.
TASK_PATTERN="$(printf '%s' "$TASK_BINARY" | sed 's/[][(){}.^$*+?|\\]/\\&/g')"
case "$TASK_MODE" in
  run|--debug|--logs|--telemetry|--verify|--sftp-preview|--space-preview|--repair-metal-cache) ;;
  *) echo "usage: $0 [--debug|--logs|--telemetry|--verify|--sftp-preview|--space-preview|--repair-metal-cache]" >&2; exit 2 ;;
esac
# Match the executable path, so another checkout or installed app stays open.
while read -r task_pid; do
  [[ -n "$task_pid" ]] && kill -TERM "$task_pid"
done < <(pgrep -f "^$TASK_PATTERN([[:space:]]|$)" || true)
if [[ "$TASK_MODE" == --repair-metal-cache ]]; then
  # Metal keeps archive URLs after the files are gone. Its bounded usage
  # index can fill after many development builds. Never move an open LMDB
  # environment or touch the installed app's cache.
  TASK_METAL_USAGE="$(getconf DARWIN_USER_CACHE_DIR)dev.noahqin.Corta.dev/com.apple.metal/archiveUsage.db"
  for task_attempt in {1..20}; do
    if ! pgrep -f "^$TASK_PATTERN([[:space:]]|$)" > /dev/null; then break; fi
    sleep 0.1
  done
  if pgrep -x CortaDev > /dev/null; then
    echo "Quit the other Corta Dev instances before repairing their shared Metal usage index." >&2
    exit 1
  fi
  if [[ -d "$TASK_METAL_USAGE" ]]; then
    if /usr/sbin/lsof -t +D "$TASK_METAL_USAGE" > /dev/null 2>&1; then
      echo "Metal's usage index is still open; quit its users before retrying." >&2
      exit 1
    fi
    TASK_METAL_BACKUP="${TASK_METAL_USAGE}.backup-$(date +%Y%m%d-%H%M%S)-$$"
    mv "$TASK_METAL_USAGE" "$TASK_METAL_BACKUP"
    echo "Previous Metal usage index saved at: $TASK_METAL_BACKUP"
  fi
fi
xcodebuild -project "$TASK_ROOT/Corta.xcodeproj" -scheme 'Corta (Dev)' \
  -configuration Debug -derivedDataPath "$TASK_ROOT/.build/ui" build
case "$TASK_MODE" in
  --debug) exec lldb -- "$TASK_BINARY" ;;
  --space-preview) /usr/bin/open -n "$TASK_APP" --args --space-preview ;;
  --sftp-preview) /usr/bin/open -n "$TASK_APP" --args --sftp-preview ;;
  *) /usr/bin/open -n "$TASK_APP" ;;
esac
case "$TASK_MODE" in
  --verify) sleep 2; pgrep -f "^$TASK_PATTERN([[:space:]]|$)" ;;
  --logs) exec /usr/bin/log stream --info --style compact --predicate 'process == "CortaDev"' ;;
  --telemetry) exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "dev.noahqin.Corta"' ;;
esac
