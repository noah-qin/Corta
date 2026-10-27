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
import Carbon.HIToolbox
import Testing
import Synchronization
@testable import Corta

struct QuickTerminalGeometryTests {
    private final class ObserverCenter: NotificationCenter, @unchecked Sendable {
        var removals = 0
        override func removeObserver(_ observer: Any) {
            removals += 1
            super.removeObserver(observer)
        }
    }
    @Test("Quick Terminal observers are installed once and released with the controller")
    @MainActor
    func observerLifetime() {
        let center = ObserverCenter()
        weak var released: QuickTerminalController?
        do {
            let controller = QuickTerminalController(notificationCenter: center)
            released = controller
            controller.observeNotifications()
            controller.observeNotifications()
            #expect(controller.observerCount == 3)
        }
        #expect(released == nil)
        #expect(center.removals == 3)
    }

    @Test("Quick Terminal teardown releases observers and can restart")
    @MainActor
    func observerTeardown() {
        let center = ObserverCenter()
        let controller = QuickTerminalController(notificationCenter: center)
        controller.observeNotifications()
        controller.teardown()
        #expect(controller.observerCount == 0 && center.removals == 3)
        controller.observeNotifications()
        #expect(controller.observerCount == 3)
        controller.teardown()
        #expect(center.removals == 6)
    }

    @Test("each Quick Terminal close removes its window observer")
    @MainActor
    func windowObserverLifetime() {
        let center = ObserverCenter()
        let controller = QuickTerminalController(notificationCenter: center)
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        for _ in 0..<4 {
            controller.observeClose(of: window)
            #expect(controller.observerCount == 1)
            center.post(name: NSWindow.willCloseNotification, object: window)
            #expect(controller.observerCount == 0)
        }
        #expect(center.removals == 4)
        controller.observeClose(of: window)
        controller.observeClose(of: window)
        #expect(controller.observerCount == 1)
        #expect(center.removals == 5)
    }

    /// hide, hide, show: the first hide's completion, arriving after the
    /// show, ordered the panel the user had just summoned back out.
    @Test("a hide's completion after a later show leaves the panel shown")
    func staleHideCompletionIsIgnored() throws {
        var visibility = QuickTerminalController.Visibility()
        let firstHide = visibility.beginHide()
        let first = try #require(firstHide)
        let again = visibility.beginHide()
        #expect(again == nil, "a second hide is the same hide")
        visibility.beginShow()
        let staleFirst = visibility.completeHide(first)
        #expect(!staleFirst)
        #expect(!visibility.isHiding)

        // show, hide, show: the hide in between is superseded too.
        let secondHide = visibility.beginHide()
        let second = try #require(secondHide)
        visibility.beginShow()
        let staleSecond = visibility.completeHide(second)
        #expect(!staleSecond)

        // An uninterrupted hide completes, once.
        let thirdHide = visibility.beginHide()
        let third = try #require(thirdHide)
        let completed = visibility.completeHide(third)
        let completedTwice = visibility.completeHide(third)
        #expect(completed && !completedTwice)
    }

    let visible = NSRect(x: 100, y: 50, width: 1000, height: 800)

    @Test("the top band spans the screen width and hangs from the visible frame's top edge")
    func topBand() {
        let frame = QuickTerminalController.frame(for: .top, in: visible)
        #expect(frame.minX == 100 && frame.width == 1000)
        #expect(frame.maxY == visible.maxY)
        #expect(frame.height == 320)
    }

    @Test("the bottom band sits on the visible frame's bottom edge, clear of the Dock")
    func bottomBand() {
        let frame = QuickTerminalController.frame(for: .bottom, in: visible)
        #expect(frame.minY == visible.minY)
        #expect(frame.width == visible.width)
        #expect(frame.height == 320)
    }

    @Test("the centred panel is centred, and smaller than the screen on both axes")
    func centered() {
        let frame = QuickTerminalController.frame(for: .center, in: visible)
        #expect(frame.midX == visible.midX && frame.midY == visible.midY)
        #expect(frame.width == 700 && frame.height == 480)
        #expect(visible.contains(frame))
    }

    @Test("a band slides in from its own edge")
    func slideDirections() {
        #expect(QuickTerminalController.slideOffset(for: .top).height > 0)
        #expect(QuickTerminalController.slideOffset(for: .bottom).height < 0)
        #expect(QuickTerminalController.slideOffset(for: .center).width == 0)
    }

    // MARK: - Display reconfiguration

    private let secondScreen = NSRect(x: 1100, y: 0, width: 1440, height: 900)

    @Test("a hidden panel is left alone: its next summon recomputes the frame anyway")
    func hiddenPanelIsNotRepositioned() {
        #expect(
            QuickTerminalController.frameAfterScreenChange(
                position: .top, isVisible: false,
                currentScreenVisibleFrame: visible, fallbackVisibleFrame: secondScreen) == nil)
    }

    @Test("a visible panel is resized in place when its own screen is still there")
    func visiblePanelKeepsItsScreen() {
        let resized = NSRect(x: 100, y: 50, width: 1000, height: 600)
        let frame = QuickTerminalController.frameAfterScreenChange(
            position: .top, isVisible: true,
            currentScreenVisibleFrame: resized, fallbackVisibleFrame: secondScreen)
        #expect(frame == QuickTerminalController.frame(for: .top, in: resized))
        // Not the other screen: a resolution change must not move a panel
        // the user is looking at onto a different display.
        #expect(frame?.minX == resized.minX)
    }

    @Test("a visible panel whose screen is gone falls back to the configured rule")
    func visiblePanelFollowsTheRuleWhenItsScreenDisappears() {
        let frame = QuickTerminalController.frameAfterScreenChange(
            position: .center, isVisible: true,
            currentScreenVisibleFrame: nil, fallbackVisibleFrame: secondScreen)
        #expect(frame == QuickTerminalController.frame(for: .center, in: secondScreen))
    }

    /// Every display is gone — a lid closed with nothing else attached.
    /// There is no frame to compute, and guessing one would put the panel
    /// at coordinates no screen contains.
    @Test("no screens at all leaves the panel untouched")
    func noScreensLeavesThePanelAlone() {
        #expect(
            QuickTerminalController.frameAfterScreenChange(
                position: .bottom, isVisible: true,
                currentScreenVisibleFrame: nil, fallbackVisibleFrame: nil) == nil)
    }

    @Test("the repositioned frame always lands inside the screen it was computed for")
    func repositionedFrameIsOnScreen() {
        for position in [
            Configuration.QuickTerminalPosition.top, .bottom, .center,
        ] {
            let frame = QuickTerminalController.frameAfterScreenChange(
                position: position, isVisible: true,
                currentScreenVisibleFrame: secondScreen, fallbackVisibleFrame: nil)
            #expect(frame.map(secondScreen.contains) == true)
        }
    }
}
