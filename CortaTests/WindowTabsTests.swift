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

/// A window's own tabs (D30): one window, one split view per tab, one shown.
@MainActor
@Suite(.serialized)
struct WindowTabsTests {
    private func makeWindow() throws -> TerminalWindowController {
        let controller = TerminalWindowController(setup: .init())
        controller.showWindow(nil)
        return controller
    }

    private func close(_ controller: TerminalWindowController) {
        for tab in controller.tabs { tab.split.teardown() }
        controller.window?.close()
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func nativeTabbingIsOffAndTheStripIsInTheTitlebarRow() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        let window = try #require(controller.window)
        #expect(window.tabbingMode == .disallowed)
        let items = window.toolbar?.items.map(\.itemIdentifier) ?? []
        #expect(items.first == .cortaTabs, "the strip leads the row, beside the traffic lights")
        #expect(controller.tabStrip.items.count == 1)
        // Tabs keep their width and sit leading; they do not fill the row.
        controller.addTab()
        let strip = controller.tabStrip
        // Laid out directly: in the toolbar, Auto Layout owns the frame.
        strip.frame.size.width = 900
        strip.layout()
        #expect(strip.tabView(at: 0)?.frame.width == TabStripView.tabWidth)
        #expect(strip.tabView(at: 1)?.frame.minX == TabStripView.tabWidth)
        strip.frame.size.width = 300
        strip.layout()
        #expect(strip.tabView(at: 1)?.frame.maxX == 300, "too many to fit: they share the row")
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func addingSelectingAndClosingTabs() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        let first = try #require(controller.selectedTab)
        let second = controller.addTab()
        let third = controller.addTab()
        #expect(controller.tabs.map(\.id) == [first, second, third].map(\.id))
        #expect(controller.selectedTab === third, "a new tab comes to the front")
        #expect(controller.tabs.filter { !$0.split.view.isHidden }.map(\.id) == [third.id])
        #expect(controller.tabStrip.items.count == 3)
        #expect(controller.tabStrip.selectedIndex == 2)

        controller.selectAdjacentTab(offset: 1)
        #expect(controller.selectedTab === first, "next wraps around")
        controller.selectAdjacentTab(offset: -1)
        #expect(controller.selectedTab === third)
        controller.selectTab(number: 1)
        #expect(controller.selectedTab === first)
        controller.selectTab(number: 9)
        #expect(controller.selectedTab === third, "⌘9 is the last tab")

        controller.closeTab(third)
        #expect(controller.tabs.count == 2)
        #expect(controller.selectedTab === second, "closing the selected tab selects its neighbour")
        #expect(third.split.panes.allSatisfy { $0.didTeardown })
        #expect(controller.window?.isVisible == true)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func reorderingKeepsTheSelection() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        let first = try #require(controller.selectedTab)
        let second = controller.addTab()
        let third = controller.addTab(select: false)
        controller.moveTab(from: 2, to: 0)
        #expect(controller.tabs.map(\.id) == [third, first, second].map(\.id))
        #expect(controller.selectedTab === second)
        #expect(controller.tabStrip.selectedIndex == 2)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aBackgroundTabNeverTakesTheKeyboard() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        let window = try #require(controller.window)
        let front = try #require(controller.selectedTab)
        let back = controller.addTab(select: false)
        #expect(controller.selectedTab === front)
        back.split.splitRight(nil)
        #expect(back.split.panes.count == 2)
        #expect(back.split.focusedPane === back.split.panes.last, "the split still focuses its new pane")
        let responder = window.firstResponder as? NSView
        #expect(back.split.panes.allSatisfy { responder?.isDescendant(of: $0.view) != true },
                "typing stays with the selected tab")
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func closingATabsLastPaneClosesOnlyThatTab() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        let first = try #require(controller.selectedTab)
        let second = controller.addTab()
        second.split.closeTabWithoutAsking()
        #expect(controller.tabs.map(\.id) == [first.id])
        #expect(controller.selectedTab === first)
        #expect(controller.window?.isVisible == true)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func eachTabIsSavedWithItsGroupIndexAndSelection() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        let first = try #require(controller.selectedTab)
        first.customTitle = "build"
        let second = controller.addTab()
        controller.selectTab(first)
        let states = controller.restorableStates
        #expect(states.map(\.id) == [first.id, second.id])
        #expect(states.map(\.tabIndex) == [0, 1])
        #expect(states.map(\.isSelectedTab) == [true, false])
        #expect(Set(states.map(\.tabGroupID)).count == 1)
        #expect(states.first?.tabGroupID != nil)
        #expect(states.first?.customTabTitle == "build")

        controller.closeTab(second)
        let alone = controller.restorableStates
        #expect(alone.count == 1)
        #expect(alone.first?.tabGroupID == nil, "a single tab is a plain window")
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aRenameShowsInTheStripAndNotFromOutput() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        let tab = try #require(controller.selectedTab)
        controller.tabStrip(controller.tabStrip, rename: 0, to: "Production")
        #expect(tab.customTitle == "Production")
        #expect(controller.tabStrip.items.first?.name == "Production")
        #expect(controller.window?.title == "Production")
        controller.tabStrip(controller.tabStrip, rename: 0, to: nil)
        #expect(tab.customTitle == nil)
    }

    /// ⇧⌘D pressed again while the last split still springs open measured a
    /// sliver and crushed the panes (dividers saved at 0.95); and a split
    /// too small for two panes is refused.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func quickSplitsKeepEveryPaneUsable() throws {
        let controller = try makeWindow()
        defer { close(controller) }
        controller.window?.setFrame(NSRect(x: 100, y: 100, width: 1000, height: 900), display: true)
        let split = try #require(controller.selectedTab?.split)
        // 900 pt: halves of 450 and 225 fit; a third ⇧⌘D would leave two
        // panes under the minimum, and is refused.
        for _ in 0..<3 { split.splitDown(nil) }
        split.splitTransition.finish()
        split.view.layoutSubtreeIfNeeded()
        #expect(split.panes.count == 3)
        for pane in split.panes {
            #expect(pane.view.frame.height >= pane.minimumContentSize.height - 1,
                    "a pane \(pane.view.frame.height) pt tall")
        }
    }

    /// A layout saved crushed comes back with each pane at least its minimum.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aCrushedSavedLayoutIsRestoredUsable() throws {
        let state = WindowState(
            frame: WindowState.Frame(NSRect(x: 100, y: 100, width: 900, height: 700)),
            layout: .split(vertical: false, position: 0.97,
                           first: .pane(directory: nil, isFocused: true), second: .pane(directory: nil)))
        let controller = TerminalWindowController(setup: .init(restore: state))
        controller.showWindow(nil)
        defer { close(controller) }
        let split = try #require(controller.selectedTab?.split)
        split.view.layoutSubtreeIfNeeded()
        #expect(split.panes.count == 2)
        for pane in split.panes {
            #expect(pane.view.frame.height >= pane.minimumContentSize.height - 1,
                    "a pane \(pane.view.frame.height) pt tall")
        }
    }
}
