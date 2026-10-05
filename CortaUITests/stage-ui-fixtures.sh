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

# Prepare the stages CursorAndWindowUITests and SystemStatusAndThemeEditorUITests
# launch the app against. The UI-test runner is sandboxed: it can read
# anywhere but write only its own container, which the app cannot read, so
# a test cannot write its own config. Each test finds a directory named
# after it under the printed root, with its config and a neutral zshrc.
#
#   TEST_RUNNER_CORTA_UI_FIXTURES="$(CortaUITests/stage-ui-fixtures.sh)" \
#     xcodebuild test -project Corta.xcodeproj -scheme Corta -testPlan UI
#
# Remove the printed root once the development app has exited.
set -euo pipefail
root="$(mktemp -d /private/tmp/corta-ui-fixtures.XXXXXX)"

stage() {
  mkdir -p "$root/$1"
  printf '%b' "$2" > "$root/$1/config"
  printf "PROMPT='demo ❯ '\n" > "$root/$1/.zshrc"
}

stage cursor-oversized 'columns = 500\nrows = 300\nrestore-windows = true\ncursor-shape = bar\ncursor-blink = true\n'
stage cursor-blink 'appearance = light\ncolumns = 90\nrows = 24\nrestore-windows = false\ncursor-shape = bar\ncursor-blink = true\n'
for name in system-status-bar system-theme-editor system-menu-preview; do
  stage "$name" 'appearance = light\nrestore-windows = false\ninput-source-indicator = off\n'
done
for language in en zh-Hans zh-Hant ja ko de fr es pt-BR; do
  stage "system-language-$language" 'appearance = light\nstatus-bar = true\nrestore-windows = false\ninput-source-indicator = off\n'
done
printf '%s\n' "$root"
