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

import AppKit

/// Full screen's transitions, which change the chrome without a tab bar
/// changing: nothing of that is owed to the window's height.
extension TerminalWindowController {
    func windowWillEnterFullScreen(_ notification: Notification) {
        beginFullScreenTransition()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        beginFullScreenTransition()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        endFullScreenTransition()
        selectedTab?.split.updateDirectPresentation()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        endFullScreenTransition()
        selectedTab?.split.updateDirectPresentation()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        endFullScreenTransition()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        endFullScreenTransition()
    }

    /// The chrome changes through a full-screen transition, not with a tab
    /// bar: none of it is owed to the window's height. Every tab, since the
    /// one shown may change before it ends.
    private func beginFullScreenTransition() {
        for tab in tabs { tab.split.isChangingFullScreen = true }
    }

    private func endFullScreenTransition() {
        for tab in tabs {
            tab.split.isChangingFullScreen = false
            tab.split.resetChromeBaseline()
        }
    }
}
