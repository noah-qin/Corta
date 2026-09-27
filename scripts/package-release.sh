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

# Packages a built Corta.app into the release archive and its SHA-256
# sidecar, then runs the same check the release workflow runs
# (`scripts/check-release.sh`) — so an archive that would be rejected on
# CI is rejected here first, for the same reason.
#
#   package-release.sh APP_PATH VERSION [OUTPUT_DIRECTORY] [--require-notarized]
set -euo pipefail

require_notarized=""
args=()
for arg in "$@"; do
  case "$arg" in
    --require-notarized) require_notarized="--require-notarized" ;;
    *) args+=("$arg") ;;
  esac
done
if [ "${#args[@]}" -lt 2 ] || [ "${#args[@]}" -gt 3 ]; then
  echo "usage: $0 APP_PATH VERSION [OUTPUT_DIRECTORY] [--require-notarized]" >&2
  exit 2
fi

app=${args[0]}
version=${args[1]}
output_directory=${args[2]:-dist}
scripts=$(cd "$(dirname "$0")" && pwd)

test -d "$app" || { echo "application not found: $app" >&2; exit 1; }
mkdir -p "$output_directory"

archive="$output_directory/Corta-$version.zip"
ditto -c -k --keepParent --sequesterRsrc "$app" "$archive"
shasum -a 256 "$archive" > "$archive.sha256"

"$scripts/check-release.sh" "$app" --version "$version" --archive "$archive" $require_notarized

echo "$archive"
cat "$archive.sha256"
