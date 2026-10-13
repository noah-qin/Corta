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

# Regenerates scripts/disk-image/DS_Store, the disk image's Finder window
# layout (D26). Run locally after changing background.tiff or the layout,
# never in CI: Finder writes the file, so it needs a logged-in session and
# permission to control Finder. Release only copies the committed result.
#
#   scripts/disk-image/make-layout.sh path/to/Corta.app
#
# Any Corta.app will do; it is there for its name and icon. The layout
# names the background by its path on a volume called Corta, which is why
# the image's volume name must not change.
set -euo pipefail

app=${1:?usage: make-layout.sh path/to/Corta.app}
here=$(cd "$(dirname "$0")" && pwd)
[[ -d "$app" ]] || { echo "not an app bundle: $app" >&2; exit 2; }
[[ ! -e /Volumes/Corta ]] || { echo "/Volumes/Corta is already mounted; eject it first" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/tmp}/corta-dmg-layout.XXXXXX")
cleanup() {
    [[ -d /Volumes/Corta ]] && { hdiutil detach /Volumes/Corta -quiet || hdiutil detach /Volumes/Corta -force -quiet; }
    rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/stage/.background"
ditto "$app" "$work/stage/Corta.app"
ln -s /Applications "$work/stage/Applications"
cp "$here/background.tiff" "$work/stage/.background/background.tiff"
hdiutil create -quiet -volname Corta -srcfolder "$work/stage" -fs APFS -format UDRW -size 64m "$work/layout.dmg"
hdiutil attach "$work/layout.dmg" -noautoopen -quiet

# Icon centres match the arrow drawn by render-background.swift.
osascript <<'EOF'
tell application "Finder"
    tell disk "Corta"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 548}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "Corta.app" of container window to {170, 180}
        set position of item "Applications" of container window to {490, 180}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF

sync
[[ -f /Volumes/Corta/.DS_Store ]] || { echo "Finder did not write a layout" >&2; exit 1; }
cp /Volumes/Corta/.DS_Store "$here/DS_Store"
xattr -c "$here/DS_Store"
echo "wrote $here/DS_Store"
