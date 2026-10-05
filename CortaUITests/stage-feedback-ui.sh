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

# Prepare shared disposable fixtures outside the UI runner's sandbox container.
set -euo pipefail
TASK_STAGE="$(mktemp -d /private/tmp/corta-feedback.XXXXXX)"
cat > "$TASK_STAGE/config" <<'CONFIG'
appearance = light
confirm-close = false
restore-windows = false
input-source-indicator = off
secure-keyboard-entry = false
CONFIG
cat > "$TASK_STAGE/fixture.sh" <<'SHELL'
#!/bin/sh
printf '\033[2J\033[H┌─────────┬─────┬───────────────┐\r\n│  Name   │ Age │     City      │\r\n├─────────┼─────┼───────────────┤\r\n│ Alice   │  30 │   New York    │\r\n└─────────┴─────┴───────────────┘\r\n\r\n┌──────┬────┐\r\n│ 中文 │ ⚠️ │\r\n└──────┴────┘\r\n'
export PS1='demo ❯ '
exec /bin/sh -i
SHELL
chmod 700 "$TASK_STAGE/fixture.sh"
printf '%s\n' "$TASK_STAGE"
