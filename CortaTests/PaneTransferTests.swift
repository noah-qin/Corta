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

@MainActor
@Suite(.serialized)
struct PaneTransferTests {
    @Test func transferPreservesControllerAndLiveSession() throws {
        let source = SplitViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = source
        _ = source.view
        source.splitRight(nil)
        let pane = try #require(source.focusedPane)
        let session = pane.session
        source.zoomFocusedPane()
        let setup = try #require(source.takeFocusedPaneForTransfer())
        let destination = SplitViewController(setup: setup)
        let newWindow = NSWindow(contentRect: window.frame, styleMask: [.titled, .resizable],
                                 backing: .buffered, defer: false)
        newWindow.contentViewController = destination
        _ = destination.view
        defer { source.teardown(); destination.teardown() }
        #expect(source.panes.count == 1)
        #expect(source.tree.leafCount == 1)
        #expect(!source.isPaneZoomed)
        #expect(destination.focusedPane === pane)
        #expect(pane.parent === destination)
        #expect(pane.session === session)
        #expect(pane.initialGridSize == nil)
        #expect(!pane.didTeardown)
        #expect(!source.panes.contains { $0 === pane })
        #expect(pane.view.isDescendant(of: destination.view))
    }

    @Test func headerButtonsStayAtTheRightAndOperateOnTheirOwnPane() throws {
        let source = SplitViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = source
        _ = source.view
        defer { source.teardown() }
        source.splitRight(nil)
        let first = try #require(source.panes.first)
        let second = try #require(source.focusedPane)
        source.view.layoutSubtreeIfNeeded()
        first.paneHeader.layoutSubtreeIfNeeded()
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        let controls = buttons(in: first.paneHeader)
        let close = try #require(controls.last)
        let frame = close.convert(close.bounds, to: first.paneHeader)
        #expect(abs(frame.maxX - (first.paneHeader.bounds.width - 8)) < 1)
        #expect(frame.width == 22)
        let parent = second.view.superview
        try #require(controls.first).performClick(nil)
        #expect(source.panes.count == 3)
        #expect(first.view.superview !== parent)
        #expect(second.view.superview === parent)
    }

    @Test func smallPaneStillRevealsWhenDividerHasNoTravel() {
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 460, height: 250))
        split.isVertical = true
        split.addArrangedSubview(NSView())
        let pane = PaneSurfaceView(frame: NSRect(x: 0, y: 0, width: 230, height: 250))
        split.addArrangedSubview(pane)
        let transition = SplitTransition()
        transition.start(node: split, from: 230, to: 230, revealing: pane) {}
        #expect(transition.isRunning)
        #expect(pane.layer?.mask != nil)
        #expect(pane.layer?.animation(forKey: "corta.split.enter") != nil)
        transition.finish()
        #expect(pane.layer?.mask == nil)
        #expect(pane.layer?.animation(forKey: "corta.split.enter") == nil)
    }

    @Test func singleAndSplitPanesShareTheInsetCardLayout() throws {
        let source = SplitViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: TerminalWindowController.styleMask, backing: .buffered, defer: false)
        window.contentViewController = source
        _ = source.view
        defer { source.teardown() }
        source.prepareWindow(window)
        source.view.layoutSubtreeIfNeeded()
        let single = try #require(source.focusedPane)
        #expect(single.view is PaneSurfaceView)
        #expect(single.view.layer?.cornerRadius == PaneSurfaceView.radius)
        #expect(abs(single.view.frame.minX - PaneSurfaceView.margin) < 1)
        #expect(abs(single.view.frame.maxX - (source.view.bounds.width - PaneSurfaceView.margin)) < 1)
        // The top margin is measured from the titlebar band less the part of
        // it the cards may use (D30).
        #expect(abs(single.view.frame.maxY - (source.view.bounds.maxY - single.windowChrome
            - PaneSurfaceView.margin + TerminalLayout.titlebarOverlap)) < 1)
        source.splitRight(nil)
        source.splitDown(nil)
        source.view.layoutSubtreeIfNeeded()
        #expect(source.panes.count == 3)
        #expect((source.tree.root as? NSSplitView)?.dividerThickness == PaneSurfaceView.gap)
        #expect(source.panes.allSatisfy { $0.view.layer?.cornerRadius == PaneSurfaceView.radius })
        source.zoomFocusedPane()
        source.view.layoutSubtreeIfNeeded()
        #expect(abs(source.zoomedPane!.view.frame.minX - PaneSurfaceView.margin) < 1)
    }

    @Test func movedPaneUsesTheSameDefaultWindowSizeAsANewTerminal() throws {
        let source = TerminalWindowController(setup: .init())
        let split = try #require(source.selectedTab?.split)
        let sourceWindow = try #require(source.window)
        sourceWindow.setFrame(NSRect(x: 50, y: 50, width: 1400, height: 850), display: false)
        split.splitRight(nil)
        split.splitDown(nil)
        let setup = try #require(split.takeFocusedPaneForTransfer())
        let moved = TerminalWindowController(setup: setup)
        let fresh = TerminalWindowController(setup: .init())
        defer {
            for controller in [source, moved, fresh] {
                controller.selectedTab?.split.teardown()
                controller.window?.close()
            }
        }
        #expect(moved.window?.frame.size == fresh.window?.frame.size)
    }

    @Test func eachOfFiveTabsRetainsItsInsetCard() throws {
        let controller = TerminalWindowController(setup: .init())
        defer {
            for tab in controller.tabs { tab.split.teardown() }
            controller.window?.close()
        }
        for _ in 0..<4 { controller.addTab() }
        #expect(controller.tabs.count == 5)
        for tab in controller.tabs {
            controller.selectTab(tab)
            let split = tab.split
            #expect(!split.view.isHidden)
            #expect(controller.tabs.filter { !$0.split.view.isHidden }.count == 1, "one tab shows")
            split.view.layoutSubtreeIfNeeded()
            let pane = try #require(split.focusedPane)
            #expect(pane.view.layer?.cornerRadius == PaneSurfaceView.radius)
            #expect(abs(pane.view.frame.minX - PaneSurfaceView.margin) < 1)
            // The card reaches `titlebarOverlap` into the titlebar band, no further.
            #expect(pane.view.frame.maxY < split.view.bounds.maxY - pane.windowChrome
                + TerminalLayout.titlebarOverlap)
        }
    }

    @Test func cannotTransferTheLastPane() {
        let source = SplitViewController()
        _ = source.view
        defer { source.teardown() }
        #expect(source.takeFocusedPaneForTransfer() == nil)
        #expect(source.panes.count == 1)
    }

    @Test func interruptingSpringSettlesAndCompletesExactlyOnce() {
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        split.isVertical = true
        split.addArrangedSubview(NSView())
        split.addArrangedSubview(NSView())
        let transition = SplitTransition()
        var completed = 0
        transition.start(node: split, from: 650, to: 400) { completed += 1 }
        #expect(transition.isRunning)
        transition.finish()
        transition.finish()
        #expect(!transition.isRunning)
        #expect(completed == 1)
        #expect(abs(split.subviews[0].frame.width - 400) < 1)
    }
}
