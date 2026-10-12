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

# Export the current brand icons with Apple's Icon Composer renderer.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEVELOPER_DIR_PATH="$(xcode-select -p)"
RENDERER="${DEVELOPER_DIR_PATH%/Contents/Developer}/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
DESTINATION="${1:-$ROOT/docs/brand}"
mkdir -p "$DESTINATION"
for name in AppIcon AppIconDev; do
  if [[ "$name" == AppIcon ]]; then stem=app-icon; else stem=app-icon-dev; fi
  for rendition in Default Dark; do
    if [[ "$rendition" == Default ]]; then suffix=""; else suffix="-dark"; fi
    "$RENDERER" "$ROOT/$name.icon" --export-image \
      --output-file "$DESTINATION/$stem$suffix.png" \
      --platform macOS --rendition "$rendition" --width 1024 --height 1024 --scale 1
  done
  "$RENDERER" "$ROOT/$name.icon" --export-image \
    --output-file "$DESTINATION/$stem-small.png" \
    --platform macOS --rendition Default --width 32 --height 32 --scale 2
done
