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

/// A pane's header shows only while its tab holds more than one pane (#527):
/// a lone pane's tab already names it, and the row goes to the grid.
///
/// The windows here are never shown, so a split or a close is not animated
/// and its sizes arrive at once; the launched app covers the animated path.
@MainActor
@Suite(.serialized, .enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
struct PaneHeaderPresenceTests {
    private func close(_ controllers: TerminalWindowController?...) {
        for controller in controllers.compactMap({ $0 }) {
            for tab in controller.tabs { tab.split.teardown() }
            controller.window?.close()
        }
    }

    private func headers(_ split: SplitViewController) -> [Bool] {
        split.panes.map { $0.showsHeader && !$0.paneHeader.isHidden }
    }

    @Test("a lone pane has no header, and its grid takes the header's height")
    func aLonePaneHasNoHeader() throws {
        let controller = TerminalWindowController(setup: .init())
        defer { close(controller) }
        let split = try #require(controller.selectedTab?.split)
        split.view.layoutSubtreeIfNeeded()
        let pane = try #require(split.focusedPane)
        #expect(headers(split) == [false])
        #expect(pane.topInset(showingHeader: true) - pane.topInset == PaneHeader.height)
        let size = pane.view.bounds.size
        let without = pane.gridSize(fitting: size)
        let with = pane.gridSize(fitting: size, showingHeader: true)
        #expect(without.rows > with.rows, "the header's row is the grid's")
        #expect(without.columns == with.columns)
    }

    @Test("a split shows a header on both panes and closing back to one hides it, one resize each")
    func splittingAndClosingFollowTheCount() throws {
        let controller = TerminalWindowController(setup: .init())
        defer { close(controller) }
        let split = try #require(controller.selectedTab?.split)
        split.view.layoutSubtreeIfNeeded()
        let first = try #require(split.focusedPane)
        #expect(first.resizesSent == 0)

        split.splitRight(nil)
        #expect(split.panes.count == 2)
        let second = try #require(split.focusedPane)
        #expect(second !== first)
        #expect(headers(split) == [true, true])
        // The new pane was born at the grid its half has, header included.
        #expect(second.resizesSent == 0, "the new pane's child keeps the size it was spawned with")
        #expect(first.resizesSent == 1, "the split pane resizes once")
        let fitted = first.gridSize(fitting: first.view.bounds.size)
        #expect(first.lastRequestedSize?.rows == fitted.rows, "the header's row is taken from the grid")

        split.closePane(second)
        #expect(split.panes.map { $0 === first } == [true])
        #expect(headers(split) == [false])
        #expect(first.resizesSent == 2, "closing back to one resizes once")
        let alone = first.gridSize(fitting: first.view.bounds.size)
        #expect(first.lastRequestedSize?.rows == alone.rows)
        #expect(first.lastRequestedSize?.columns == alone.columns)
    }

    /// In a shown window the close is animated, and the survivor is resized
    /// to its settled size before the closing pane is gone: with the header
    /// it is about to lose, or it would resize a second time at the end.
    @Test("closing back to one in a shown window resizes the survivor once")
    func anAnimatedCloseResizesOnce() throws {
        let controller = TerminalWindowController(setup: .init())
        controller.showWindow(nil)
        defer { close(controller) }
        let split = try #require(controller.selectedTab?.split)
        split.view.layoutSubtreeIfNeeded()
        let first = try #require(split.focusedPane)
        split.splitRight(nil)
        split.splitTransition.finish()
        split.view.layoutSubtreeIfNeeded()
        let second = try #require(split.focusedPane)
        #expect(headers(split) == [true, true])
        let before = first.resizesSent
        #expect(before == 1, "the animated split resizes the split pane once")
        #expect(second.resizesSent == 0)

        split.closePane(second)
        split.splitTransition.finish()
        split.view.layoutSubtreeIfNeeded()
        #expect(split.panes.count == 1)
        #expect(headers(split) == [false])
        #expect(first.resizesSent == before + 1, "one resize, to the size it keeps")
        let alone = first.gridSize(fitting: first.view.bounds.size)
        #expect(first.lastRequestedSize?.rows == alone.rows)
        #expect(first.lastRequestedSize?.columns == alone.columns)
    }

    @Test("a pane moved to another tab shows the header by its new tab's count, and the tab it left by its own")
    func aMovedPaneFollowsItsNewTab() throws {
        let controller = TerminalWindowController(setup: .init())
        defer { close(controller) }
        let source = try #require(controller.selectedTab)
        let target = controller.addTab()
        controller.selectTab(source)
        source.split.view.layoutSubtreeIfNeeded()
        source.split.splitRight(nil)
        let moving = try #require(source.split.focusedPane)
        #expect(headers(source.split) == [true, true])
        #expect(headers(target.split) == [false])

        source.split.moveFocusedPane(to: target)
        #expect(target.split.panes.contains { $0 === moving })
        #expect(headers(target.split) == [true, true], "two panes in the tab it joined")
        #expect(headers(source.split) == [false], "one left behind")

        // To a tab of its own: alone again.
        target.split.noteFocus(moving)
        target.split.movePaneToNewTab(nil)
        let own = try #require(controller.tabs.first { $0.split.panes.contains { $0 === moving } })
        #expect(own !== target)
        #expect(headers(own.split) == [false])
        #expect(headers(target.split) == [false])
    }

    @Test("a restored single pane is born without a header, a restored split with both")
    func restoredTabsFollowTheirCount() throws {
        let frame = WindowState.Frame(NSRect(x: 100, y: 100, width: 1000, height: 640))
        let single = TerminalWindowController(setup: .init(restore: WindowState(
            frame: frame, layout: .pane(directory: nil, isFocused: true))))
        let splitState = TerminalWindowController(setup: .init(restore: WindowState(
            frame: frame,
            layout: .split(vertical: true, position: 0.5,
                           first: .pane(directory: nil, isFocused: true), second: .pane(directory: nil)))))
        defer { close(single, splitState) }
        let lone = try #require(single.selectedTab?.split)
        #expect(headers(lone) == [false])
        let pair = try #require(splitState.selectedTab?.split)
        // A restore's splits are rebuilt as the tab appears.
        pair.applyPendingRestore()
        pair.view.layoutSubtreeIfNeeded()
        #expect(pair.panes.count == 2)
        #expect(headers(pair) == [true, true])
        for pane in pair.panes {
            let fitted = pane.gridSize(fitting: pane.view.bounds.size)
            #expect(pane.lastRequestedSize?.rows == fitted.rows, "the grid leaves the header its row")
        }
    }

    /// Without a header a lone pane is still split from the menu, the palette
    /// and ⌘D/⇧⌘D — all of them the split view's actions — and closed by ⌘W.
    @Test("a lone pane splits and closes without its header's buttons")
    func aLonePaneIsStillSplitAndClosed() throws {
        let controller = TerminalWindowController(setup: .init())
        defer { close(controller) }
        let split = try #require(controller.selectedTab?.split)
        split.view.layoutSubtreeIfNeeded()
        let item = NSMenuItem(title: "", action: #selector(SplitViewController.splitDown(_:)), keyEquivalent: "")
        #expect(split.validateMenuItem(item), "Split Down is offered with one pane")
        split.splitDown(nil)
        #expect(split.panes.count == 2)
        #expect(headers(split) == [true, true])
    }
}
