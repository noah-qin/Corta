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

# The terminal host has broad access; its decoder gets an independent sandbox.
#
# The app target runs this with ENABLE_USER_SCRIPT_SANDBOXING = NO. In an
# archive, $BUILT_PRODUCTS_DIR/corta-image-decoder is a symlink into
# UninstalledProducts, and Xcode 26's script sandbox refuses to read through
# it ("Operation not permitted"); only `xcodebuild archive` takes that path.
set -euo pipefail
helper_app="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/CortaImageDecoder.app"
# codesign uses unpredictable temporary sibling names. Sign in the build
# sandbox's temporary directory, then copy only the declared output files.
helper_stage="$(mktemp -d "${TMPDIR%/}/corta-decoder.XXXXXX")"
trap 'rm -rf "$helper_stage"' EXIT
staged_app="$helper_stage/CortaImageDecoder.app"
mkdir -p "$staged_app/Contents/MacOS"
cp "$BUILT_PRODUCTS_DIR/corta-image-decoder" "$staged_app/Contents/MacOS/corta-image-decoder"
cp "$SRCROOT/scripts/image-decoder/Info.plist" "$staged_app/Contents/Info.plist"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]]; then
    /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
        --options runtime --entitlements "$SRCROOT/scripts/image-decoder/Decoder.entitlements" \
        "$staged_app"
fi
mkdir -p "$helper_app/Contents/MacOS"
cp "$staged_app/Contents/MacOS/corta-image-decoder" "$helper_app/Contents/MacOS/corta-image-decoder"
cp "$staged_app/Contents/Info.plist" "$helper_app/Contents/Info.plist"
if [[ -f "$staged_app/Contents/_CodeSignature/CodeResources" ]]; then
    mkdir -p "$helper_app/Contents/_CodeSignature"
    cp "$staged_app/Contents/_CodeSignature/CodeResources" "$helper_app/Contents/_CodeSignature/CodeResources"
fi
