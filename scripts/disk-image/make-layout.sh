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
# Any Corta.app will do; it is there for its name and icon. Finder stores
# the background as a bookmark holding the volume name and the path of the
# image file it came from, and that bookmark ships in every release. So the
# scratch image always lives at the same neutral path, never under $TMPDIR
# (which names the machine's per-user folder), and the volume is Corta, the
# name corta-release-check requires.
set -euo pipefail

app=${1:?usage: make-layout.sh path/to/Corta.app}
here=$(cd "$(dirname "$0")" && pwd)
work=/private/tmp/corta-dmg-layout
mount=/Volumes/Corta
[[ -d "$app" ]] || { echo "not an app bundle: $app" >&2; exit 2; }
[[ ! -e "$work" ]] || { echo "$work exists; remove it first" >&2; exit 2; }
[[ ! -e "$mount" ]] || { echo "$mount exists; eject it first" >&2; exit 2; }
# Finder finds the volume by name, so no volume may be called Corta,
# wherever it is mounted.
if [[ $(osascript -e 'tell application "Finder" to count (disks whose name is "Corta")') != 0 ]]; then
    echo "a volume named Corta is mounted; eject it first" >&2; exit 2
fi

mkdir "$work"
cleanup() {
    [[ -d "$mount" ]] && { hdiutil detach "$mount" -quiet || hdiutil detach "$mount" -force -quiet; }
    rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/stage/.background"
ditto "$app" "$work/stage/Corta.app"
ln -s /Applications "$work/stage/Applications"
cp "$here/background.tiff" "$work/stage/.background/background.tiff"
hdiutil create -quiet -volname Corta -srcfolder "$work/stage" -fs APFS -format UDRW "$work/Corta.dmg"
hdiutil attach "$work/Corta.dmg" -noautoopen -quiet -mountpoint "$mount"

# The outer frame for 660 x 400 pt of content, measured on this macOS
# rather than assumed: the title bar was 28 pt and is 32 pt on macOS 26. A
# frame too short leaves the content smaller than the background, and the
# window scrolls to show Finder's own colour.
height=$(swift -e 'import AppKit
print(Int(NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 660, height: 400),
    styleMask: [.titled, .closable, .miniaturizable, .resizable]).height))')

# Icon centres match the arrow drawn by render-background.swift.
osascript - "$height" <<'APPLESCRIPT'
on run argv
    set frameHeight to (item 1 of argv) as integer
    tell application "Finder"
        tell disk "Corta"
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {200, 120, 860, 120 + frameHeight}
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
end run
APPLESCRIPT

sync
[[ -f "$mount/.DS_Store" ]] || { echo "Finder did not write a layout" >&2; exit 1; }
# The layout is published: refuse one that names anything on this machine
# other than the scratch path above.
if strings -a "$mount/.DS_Store" | grep -q -e /var/folders -e "$HOME" -e "$USER"; then
    echo "the layout names a local path; not writing it" >&2; exit 1
fi
cp "$mount/.DS_Store" "$here/DS_Store"
xattr -c "$here/DS_Store"
echo "wrote $here/DS_Store (frame height $height)"
