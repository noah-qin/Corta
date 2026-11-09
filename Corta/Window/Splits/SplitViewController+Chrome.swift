// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

import Cocoa

/// The window's chrome height, which a tab bar changes and the window's
/// frame absorbs.
extension SplitViewController {
    /// Takes the window's chrome as it is now as the baseline, owing nothing:
    /// after a full-screen transition, whose chrome is not the windowed
    /// one's. Measured during full screen and compared after it, the
    /// difference grew the window on every exit.
    func resetChromeBaseline() {
        guard let window = view.window, didSetUpWindow else { return }
        lastChromeHeight = window.frame.height - window.contentLayoutRect.height
    }

    /// A tab bar appearing or disappearing changes the chrome height; AppKit
    /// would shrink the content area and cost every pane rows. Absorb the
    /// delta into the frame instead (the window grows downward).
    ///
    /// Called from `viewDidLayout`, and from `AppDelegate.newTab` for the
    /// window a new tab covers, which never lays out again on its own.
    func absorbChromeChange() {
        // Not before the window is sized and shown: until then there is no
        // chrome to keep.
        guard isSelectedTab, let window = view.window, didSetUpWindow, window.isVisible
        else { return }
        let chrome = window.frame.height - window.contentLayoutRect.height
        let last = lastChromeHeight
        // Recorded before `setFrame`, which lays out reentrantly and would
        // otherwise absorb the same delta twice.
        lastChromeHeight = chrome
        guard !isChangingFullScreen, let last, chrome != last else { return }
        growWindow(by: chrome - last, needsRoom: false)
    }

    /// Grows the window downward by `delta` (or gives it back), so the
    /// panes keep their size. Only the selected tab's window, once it is
    /// sized and shown, not while the user drags it or in full screen.
    /// With `needsRoom`, only where the grown window still fits the screen.
    /// Returns whether the window moved.
    @discardableResult
    func growWindow(by delta: CGFloat, needsRoom: Bool) -> Bool {
        guard delta != 0, isSelectedTab, let window = view.window, didSetUpWindow, window.isVisible,
            !window.inLiveResize, !window.styleMask.contains(.fullScreen) else { return false }
        var frame = window.frame
        frame.origin.y -= delta
        frame.size.height += delta
        if needsRoom {
            guard let visible = window.screen?.visibleFrame else { return false }
            if frame.minY < visible.minY { frame.origin.y = visible.minY }
            guard frame.maxY <= visible.maxY, frame.height <= visible.height else { return false }
        }
        window.setFrame(frame, display: true)
        return true
    }
}
