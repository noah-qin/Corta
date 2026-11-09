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
import Testing

@testable import Corta

/// What a window shows of state that is not its panes': the secure-input
/// lock, the chrome a full-screen transition changes, and a close question
/// a quit must not ask twice.
@MainActor
@Suite(.serialized)
struct WindowChromeStateTests {
    private func makeWindow() -> TerminalWindowController {
        let controller = TerminalWindowController(setup: .init())
        controller.showWindow(nil)
        return controller
    }

    private func close(_ controller: TerminalWindowController) {
        for tab in controller.tabs { tab.split.teardown() }
        controller.window?.close()
    }

    /// Moving between two terminal windows leaves secure input engaged, so
    /// only the window's own key change can move the lock.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func theLockFollowsTheWindowsOwnKeyState() throws {
        let controller = makeWindow()
        defer { close(controller) }
        var isKey = true
        controller.secureInputIsEngaged = { true }
        controller.windowIsKey = { isKey }
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        #expect(controller.secureInputIndicator?.isHidden == false)
        isKey = false
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        #expect(controller.secureInputIndicator?.isHidden == true)
    }

    /// The chrome measured in full screen was compared with the windowed
    /// chrome after it, and the difference grew the window on every exit.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aFullScreenTransitionOwesTheWindowNoHeight() throws {
        let controller = makeWindow()
        defer { close(controller) }
        let window = try #require(controller.window)
        let split = try #require(controller.selectedTab?.split)
        let frame = window.frame
        controller.windowWillExitFullScreen(Notification(name: NSWindow.willExitFullScreenNotification))
        #expect(split.isChangingFullScreen)
        split.absorbChromeChange()
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification))
        #expect(!split.isChangingFullScreen)
        split.absorbChromeChange()
        #expect(window.frame == frame)
    }
}
