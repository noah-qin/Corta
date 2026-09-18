#!/bin/bash
# Read only: DEVELOPER_DIR scopes tool selection to this process.
set -euo pipefail
channel="${1:-unspecified}"
case "$channel" in stable|preview|unspecified) ;; *) echo 'Usage: record-toolchain.sh [stable|preview|unspecified]' >&2; exit 2 ;; esac
printf 'Channel: %s\nDeveloper directory: %s\n' "$channel" "${DEVELOPER_DIR:-$(xcode-select -p)}"
xcodebuild -version
xcrun swift --version
printf 'macOS SDK: %s\n' "$(xcrun --sdk macosx --show-sdk-version)"
printf 'SDK build: %s\n' "$(xcrun --sdk macosx --show-sdk-build-version)"
printf 'Swift language mode: 6\nSwiftPM tools minimum: 6.2\nDeployment target: macOS 26.0\n'
sw_vers
