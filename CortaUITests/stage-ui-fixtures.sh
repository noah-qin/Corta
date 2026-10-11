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

# Prepare the stages CursorAndWindowUITests, SystemStatusAndThemeEditorUITests,
# InputSourceIndicatorUITests and DirectoryCompletionUITests launch the app
# against. The UI-test runner is sandboxed: it can read
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

stage measurement 'columns = 120\nrows = 40\nfont-size = 14\nrestore-windows = false\ncursor-blink = false\nstatus-bar = false\ninput-source-indicator = off\nsecure-keyboard-entry = false\nconfirm-close = false\nupdate-auto-check = false\nsuggest-applications-folder = false\n'
stage terminal-recovery 'restore-windows = false\ncursor-blink = false\nstatus-bar = false\ninput-source-indicator = off\nsecure-keyboard-entry = false\nconfirm-close = false\ncolumns = 90\nrows = 24\n'
stage cursor-oversized 'columns = 500\nrows = 300\nrestore-windows = true\ncursor-shape = bar\ncursor-blink = true\n'
stage cursor-blink 'appearance = light\ncolumns = 90\nrows = 24\nrestore-windows = false\ncursor-shape = bar\ncursor-blink = true\n'
for name in system-status-bar system-theme-editor system-menu-preview; do
  stage "$name" 'appearance = light\nrestore-windows = false\ninput-source-indicator = off\n'
done
for language in en zh-Hans zh-Hant ja ko de fr es pt-BR; do
  stage "system-language-$language" 'appearance = light\nstatus-bar = true\nrestore-windows = false\ninput-source-indicator = off\n'
done
# The input-source indicator: a 60×18 grid each test checks with `stty size`
# before it trusts anything else it sees.
input_source='columns = 60\nrows = 18\nrestore-windows = false\nfont-size = 14\n'
stage input-source-toolbar "appearance = light\n$input_source"
stage input-source-cjk "appearance = light\n$input_source"
stage input-source-dark "appearance = dark\n$input_source"
stage input-source-prompt "appearance = light\n${input_source}input-source-indicator-position = prompt\n"
for name in input-source-toolbar input-source-cjk input-source-dark input-source-prompt; do
  printf "PROMPT='demo ❯ '\nRPROMPT=''\n" > "$root/$name/.zshrc"
done
# A shell without integration, for the fallback placement.
printf '#!/bin/sh\nexport PS1="demo ❯ "\nexec /bin/sh --noprofile --norc -i\n' > "$root/input-source-dark/plain-shell"
chmod 700 "$root/input-source-dark/plain-shell"

# Directory completion: the folders it offers, one of them hidden, one of
# them a name with a space and CJK in it.
stage directory-completion 'restore-windows = false\n'
for name in Alpha Another '空格 中文' .hidden; do
  mkdir -p "$root/directory-completion/Demo/$name"
done

printf '%s\n' "$root"
