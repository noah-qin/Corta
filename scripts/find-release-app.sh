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

# Prints the path to the most recently built Release Corta.app, or exits 1
# with a message on stderr. Shared by the measurement scripts in this
# directory so each doesn't re-guess the DerivedData path.
set -euo pipefail

app=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -maxdepth 6 -type d -path "*/Build/Products/Release/Corta.app" \
  -print0 2>/dev/null | xargs -0 ls -dt 2>/dev/null | head -1)

if [ -z "$app" ] || [ ! -d "$app" ]; then
  echo "error: no Release Corta.app found under DerivedData." >&2
  echo "  Build one first:" >&2
  echo "  xcodebuild -project Corta.xcodeproj -scheme Corta -configuration Release build" >&2
  exit 1
fi

echo "$app"
