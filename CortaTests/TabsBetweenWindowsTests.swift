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
import CortaTerminal
import Testing

@testable import Corta

/// Tabs between windows (D30, phase 2), ⌃Tab, and the strip's views.
@MainActor
@Suite(.serialized)
struct TabsBetweenWindowsTests {
    private func makeWindow() -> TerminalWindowController {
        let controller = TerminalWindowController(setup: .init())
        controller.showWindow(nil)
        return controller
    }

    private func close(_ controllers: TerminalWindowController?...) {
        for controller in controllers.compactMap({ $0 }) {
            for tab in controller.tabs { tab.split.teardown() }
            controller.window?.close()
        }
    }

    @Test func controlTabSteps() throws {
        func event(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        }
        #expect(TerminalView.tabCycleStep(for: try event([.control])) == 1)
        #expect(TerminalView.tabCycleStep(for: try event([.control, .shift])) == -1)
        #expect(TerminalView.tabCycleStep(for: try event([])) == nil, "a plain Tab is the program's")
        #expect(TerminalView.tabCycleStep(for: try event([.control, .option])) == nil)
    }

    /// AppKit takes ⌃Tab for the key-view loop before `keyDown`; the
    /// terminal claims it as a key equivalent.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func controlTabReachesTheTabsAsAKeyEquivalent() throws {
        let controller = makeWindow()
        defer { close(controller) }
        let first = try #require(controller.selectedTab)
        controller.addTab()
        let view = try #require(controller.selectedTab?.split.focusedPane?.terminalView)
        controller.window?.makeFirstResponder(view)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0,
            windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: "\t",
            charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        #expect(view.performKeyEquivalent(with: event))
        #expect(controller.selectedTab === first, "wrapped round to the first tab")
    }

    /// Tabs share a window: only the front tab's focused pane is focused
    /// for focus reports (?1004) and notifications.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func onlyTheFrontTabsPaneHoldsTheWindowsFocus() throws {
        let controller = makeWindow()
        defer { close(controller) }
        let first = try #require(controller.selectedTab?.split.focusedPane)
        let second = try #require(controller.addTab().split.focusedPane)
        #expect(first.isFocusedPane, "still its own tab's focused pane")
        #expect(!first.holdsWindowFocus)
        #expect(second.holdsWindowFocus)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aMovedTabKeepsItsRunningPanes() throws {
        let source = makeWindow()
        let first = try #require(source.selectedTab)
        let moving = source.addTab()
        let session = moving.split.focusedPane?.session
        let target = try #require(source.moveToNewWindow(moving))
        defer { close(source, target) }
        #expect(source.tabs.map(\.id) == [first.id])
        #expect(target.tabs.first === moving, "the same tab, not a copy")
        #expect(moving.controller === target)
        #expect(moving.split.focusedPane?.session === session, "its shell runs on")
        #expect(moving.split.view.window === target.window)
        // Dressed as a window born with its tab: no title text over the strip.
        #expect(target.window?.titleVisibility == .hidden)
        #expect(target.window?.titlebarAppearsTransparent == true)
        #expect(source.release(first) == false, "a window keeps its last tab")
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func mergingGathersEveryTabAndKeepsTheFrontOne() throws {
        let a = makeWindow()
        let b = makeWindow()
        let front = try #require(a.selectedTab)
        let bFirst = try #require(b.selectedTab)
        let bSecond = b.addTab()
        a.merge([a, b])
        defer { close(a, b) }
        #expect(a.tabs.map(\.id) == [front.id, bFirst.id, bSecond.id])
        #expect(a.selectedTab === front)
        #expect(b.tabs.isEmpty)
        #expect(b.window?.isVisible == false)
        #expect(bSecond.split.view.window === a.window)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aWindowGivingUpItsLastTabCloses() throws {
        let a = makeWindow()
        let b = makeWindow()
        let lone = try #require(b.selectedTab)
        a.take(lone, from: b, at: 0)
        defer { close(a, b) }
        #expect(a.tabs.first === lone)
        #expect(a.selectedTab === lone)
        #expect(b.window?.isVisible == false)
    }

    /// Closing the middle tab takes its own view away: by position, the last
    /// view went and every name after the middle shifted along.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func theStripKeepsAViewWithItsTab() throws {
        let controller = makeWindow()
        defer { close(controller) }
        controller.addTab()
        let third = controller.addTab()
        let views = (0..<3).compactMap { controller.tabStrip.tabView(at: $0) }
        controller.closeTab(controller.tabs[1])
        #expect(controller.tabStrip.tabView(at: 0) === views[0])
        #expect(controller.tabStrip.tabView(at: 1) === views[2])
        #expect((controller.tabStrip.tabView(at: 1) as? TabItemView)?.itemID == third.id)
    }
}

/// What a tab being moved, closed or put behind must not do to the others.
@MainActor
@Suite(.serialized)
struct TabLifecycleTests {
    private func makeWindow() -> TerminalWindowController {
        let controller = TerminalWindowController(setup: .init())
        controller.showWindow(nil)
        return controller
    }

    private func close(_ controllers: TerminalWindowController?...) {
        for controller in controllers.compactMap({ $0 }) {
            for tab in controller.tabs { tab.split.teardown() }
            controller.window?.close()
        }
    }

    /// Past the hold and the fade, on the clock that stops while the Mac sleeps.
    private func settle() async throws {
        let wait = TabContainerViewController.holdLimit + TabContainerViewController.fadeDuration + 0.2
        try await Task.sleep(for: .seconds(wait), clock: .suspending)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aTabMovedDuringItsHoldStaysShownInItsNewWindow() async throws {
        let source = makeWindow()
        let held = try #require(source.selectedTab)
        let front = source.addTab(select: false)
        source.selectTab(front, holding: held.split)
        let target = try #require(source.moveToNewWindow(held))
        defer { close(source, target) }
        try await settle()
        #expect(!held.split.view.isHidden, "the old window's hold ended with the move")
        #expect(held.split.view.alphaValue == 1)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aTabMovedDuringItsFadeStaysShownInItsNewWindow() async throws {
        let source = makeWindow()
        let held = try #require(source.selectedTab)
        let front = source.addTab(select: false)
        source.selectTab(front, holding: held.split)
        source.container.releaseHeld()
        let target = try #require(source.moveToNewWindow(held))
        defer { close(source, target) }
        #expect(held.split.view.alphaValue == 1, "the fade stopped at the move")
        try await settle()
        #expect(!held.split.view.isHidden)
        #expect(held.split.view.alphaValue == 1)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aMovedWindowIsNotRestorableAndASwitchRestoresItsIncrements() throws {
        let source = makeWindow()
        let first = try #require(source.selectedTab)
        let moving = source.addTab()
        let target = try #require(source.moveToNewWindow(moving))
        defer { close(source, target) }
        #expect(target.window?.isRestorable == false)
        let window = try #require(source.window)
        source.addTab()
        let metrics = try #require(first.split.focusedPane?.terminalRenderer?.pointMetrics)
        // As AppKit keeps it: the value read back need not be the one set.
        window.contentResizeIncrements = NSSize(width: metrics.cellWidth, height: metrics.cellHeight)
        let expected = window.contentResizeIncrements
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
        source.selectTab(first)
        #expect(window.contentResizeIncrements == expected, "\(metrics.cellWidth)x\(metrics.cellHeight)")
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aBackgroundTabsFinishIsNews() throws {
        let controller = makeWindow()
        defer { close(controller) }
        let first = try #require(controller.selectedTab?.split.focusedPane)
        let second = try #require(controller.addTab().split.focusedPane)
        #expect(!first.taskNotifier.tabInFront())
        #expect(second.taskNotifier.tabInFront())
    }

    /// A hidden tab draws no frame, so the batch stage never runs for it; a
    /// command's boundaries have to arrive some other way.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aHiddenTabStillSeesItsCommandStart() async throws {
        let controller = makeWindow()
        defer { close(controller) }
        let hidden = try #require(controller.selectedTab?.split.focusedPane)
        controller.addTab()
        controller.container.releaseHeld(animated: false)
        #expect(hidden.view.isHiddenOrHasHiddenAncestor)
        let session = try #require(hidden.session)
        // A shell's OSC 133 A, then C. Typed at the shell, which prints it.
        _ = session.write(Array("printf '\\033]133;A\\007\\033]133;C\\007'; sleep 30\n".utf8))
        let deadline = SuspendingClock.now + .seconds(10) * testTimeoutScale
        while !hidden.taskNotifier.isCommandRunningNoted, SuspendingClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(hidden.taskNotifier.isCommandRunningNoted)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aWindowAskingInASheetIsNotMergedAway() throws {
        let a = makeWindow()
        let b = makeWindow()
        defer { close(a, b) }
        let bWindow = try #require(b.window)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                             styleMask: .titled, backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        bWindow.beginSheet(sheet)
        defer { bWindow.endSheet(sheet) }
        let lone = try #require(b.selectedTab)
        let before = a.tabs.count
        a.merge([a, b])
        #expect(a.tabs.count == before)
        #expect(b.tabs.first === lone)
        #expect(bWindow.isVisible)
        a.take(lone, from: b, at: 0)
        #expect(b.tabs.first === lone, "nor is its tab taken from under the question")
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func controlTabLeavesAKeyTheUserBoundAndALoneTab() throws {
        let controller = makeWindow()
        defer { close(controller) }
        let view = try #require(controller.selectedTab?.split.focusedPane?.terminalView)
        controller.window?.makeFirstResponder(view)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0,
            windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: "\t",
            charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        #expect(!view.performKeyEquivalent(with: event), "one tab: nothing to cycle to")
        let first = try #require(controller.selectedTab)
        let second = controller.addTab()
        controller.selectTab(first)
        controller.window?.makeFirstResponder(view)
        var bindings = Keybindings()
        bindings[.newWindow] = Shortcut("\t", [.control])
        view.keybindings = { bindings }
        #expect(!view.performKeyEquivalent(with: event), "the user's binding, for the menu")
        #expect(controller.selectedTab === first)
        _ = second
    }
}

/// The parts of the strip that need no window.
@MainActor
@Suite
struct TabStripPartsTests {
    private func item(_ id: String) -> TabStripItem {
        TabStripItem(id: id, programs: [.terminal], name: id, context: "", toolTip: id)
    }

    @Test func aTabClosedUnderADragTakesThePreviewWithIt() {
        let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: 400, height: TabStripView.height))
        strip.update(items: [item("a"), item("b")], selectedIndex: 0)
        let preview = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        preview.isReleasedWhenClosed = false
        strip.dragPreview = preview
        strip.drag = .init(index: 1, start: .zero, moved: true, tornOff: true)
        strip.update(items: [item("a")], selectedIndex: 0)
        #expect(strip.drag == nil)
        #expect(strip.dragPreview == nil)
    }

    @Test func aDoubleClickOnALeavingTabReachesNothing() throws {
        let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: 400, height: TabStripView.height))
        strip.update(items: [item("a")], selectedIndex: 0)
        let view = try #require(strip.tabView(at: 0) as? TabItemView)
        view.frame = strip.bounds
        #expect(view.hitTest(NSPoint(x: 10, y: 10)) != nil)
        view.isLeaving = true
        #expect(view.hitTest(NSPoint(x: 10, y: 10)) == nil)
    }

    @Test func thePressOfAStaleIndexIsIgnored() throws {
        let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: 400, height: TabStripView.height))
        strip.update(items: [item("a")], selectedIndex: 0)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        strip.itemMouseDown(5, event: event)
        #expect(strip.drag == nil)
    }

    @Test func theBadgeSaysWhatItsDotMeans() {
        #expect(TabItemView.badgeLabel(status: nil, progress: nil) == nil)
        let progress = TabItemView.badgeLabel(status: nil, progress: ProgramProgress(state: .normal, value: 40))
        #expect(progress?.contains("40%") == true)
    }

    @Test func aClickPassesThroughATabNoLongerInFront() {
        let content = WindowContentView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let below = NSView(frame: content.bounds)
        let above = NSView(frame: content.bounds)
        content.addSubview(below)
        content.addSubview(above)
        #expect(content.hitTest(NSPoint(x: 50, y: 50)) === above)
        content.inert.add(above)
        #expect(content.hitTest(NSPoint(x: 50, y: 50)) === below)
        content.inert.remove(above)
        #expect(content.hitTest(NSPoint(x: 50, y: 50)) === above)
    }

    @Test func aFinishIsWatchedOnlyInTheTabInFrontOfTheKeyWindow() {
        #expect(TaskNotifier.isWatched(windowIsKey: true, tabInFront: true))
        #expect(!TaskNotifier.isWatched(windowIsKey: true, tabInFront: false))
        #expect(!TaskNotifier.isWatched(windowIsKey: false, tabInFront: true))
    }

    @Test func settingsSearchFindsWhatThePagesShow() {
        #expect(SettingsView.Category.appearance.matches(L10n.text("settings.section.colorScheme")))
        #expect(SettingsView.Category.themes.matches(L10n.text("settings.themes.ansiColors")))
    }
}
