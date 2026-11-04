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
