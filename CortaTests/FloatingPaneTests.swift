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
struct FloatingPaneTests {
    private func makeSource() throws -> (TerminalWindowController, SplitViewController) {
        let controller = TerminalWindowController(setup: .init())
        let split = try #require(controller.contentViewController as? SplitViewController)
        split.splitRight(nil)
        return (controller, split)
    }

    private func stop(_ controller: TerminalWindowController, _ source: SplitViewController) {
        source.teardown()
        controller.window?.close()
    }

    @Test func floatingPaneHasNoTitlebarAndDocksBackWithoutRestarting() throws {
        let (controller, source) = try makeSource()
        defer { stop(controller, source) }
        let pane = try #require(source.focusedPane)
        let session = pane.session
        let before = pane.view.convert(pane.view.bounds, to: source.view)
        let floating = try #require(source.floatFocusedPane())
        let window = try #require(floating.window)
        #expect(!window.styleMask.contains(.titled))
        #expect(window.toolbar == nil)
        #expect(window.canBecomeKey)
        #expect(window.hasShadow)
        #expect(window.frame.size == FloatingPaneController.defaultSize)
        #expect(floating.split.isFloating)
        #expect(floating.split.contentMargin == 0)
        #expect(floating.split.focusedPane === pane)
        #expect(pane.session === session)
        #expect(source.panes.count == 1)
        floating.dock()
        #expect(source.panes.count == 2)
        #expect(source.floatingPanels.isEmpty)
        #expect(floating.split.panes.isEmpty)
        #expect(pane.parent === source)
        #expect(pane.session === session)
        #expect(!pane.didTeardown)
        #expect(pane.view.convert(pane.view.bounds, to: source.view) == before)
    }

    @Test(arguments: [true, false])
    func dockingRestoresEitherSideOfANestedLayout(floatFirst: Bool) throws {
        let (controller, source) = try makeSource()
        defer { stop(controller, source) }
        source.splitDown(nil)
        if floatFirst { source.noteFocus(try #require(source.panes.first)) }
        let panes = source.panes
        let before = panes.map { $0.view.convert($0.view.bounds, to: source.view) }
        let floating = try #require(source.floatFocusedPane())
        floating.dock()
        #expect(source.tree.leafCount == 3)
        for (pane, frame) in zip(panes, before) {
            #expect(pane.view.convert(pane.view.bounds, to: source.view) == frame)
            #expect(!pane.didTeardown)
        }
    }

    @Test func highlightedFloatButtonEmbedsThePaneBack() throws {
        let (controller, source) = try makeSource()
        defer { stop(controller, source) }
        let floating = try #require(source.floatFocusedPane())
        let pane = try #require(floating.split.focusedPane)
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        pane.paneHeader.refresh()
        let button = try #require(buttons(in: pane.paneHeader).first { $0.action == NSSelectorFromString("detach") })
        #expect(button.isEnabled)
        #expect(button.toolTip == L10n.text("command.dockPane"))
        button.performClick(nil)
        #expect(pane.parent === source)
        #expect(source.floatingPanels.isEmpty)
        #expect(button.toolTip == L10n.text("command.detachPane"))
    }

    @Test func repeatedFloatAndDockDoesNotLoseThePaneOrItsSession() throws {
        let (controller, source) = try makeSource()
        defer { stop(controller, source) }
        let pane = try #require(source.focusedPane)
        let session = pane.session
        for _ in 0..<4 {
            let floating = try #require(source.floatFocusedPane())
            floating.dock()
            #expect(source.panes.count == 2)
            #expect(source.tree.leafCount == 2)
            #expect(source.focusedPane === pane)
            #expect(pane.session === session)
            #expect(!pane.didTeardown)
        }
    }

    @Test func splitFloatingGroupDocksTogether() throws {
        let (controller, source) = try makeSource()
        defer { stop(controller, source) }
        let floating = try #require(source.floatFocusedPane())
        floating.split.splitDown(nil)
        let panes = floating.split.panes
        #expect(panes.count == 2)
        floating.dock()
        #expect(source.panes.count == 3)
        #expect(source.tree.leafCount == 3)
        #expect(panes.allSatisfy { $0.parent === source && !$0.didTeardown })
    }

    @Test func dockingStillWorksAfterOriginalSiblingWasClosed() throws {
        let (controller, source) = try makeSource()
        defer { stop(controller, source) }
        source.splitDown(nil)
        let floating = try #require(source.floatFocusedPane())
        let pane = try #require(floating.split.focusedPane)
        let sibling = try #require(source.panes.first { $0.view === floating.anchor.sibling })
        source.closePane(sibling)
        floating.dock()
        #expect(source.panes.count == 2)
        #expect(source.tree.leaves.contains { $0 === pane.view })
        #expect(!pane.didTeardown)
    }

    @Test func closingSourceStopsItsFloatingSessions() throws {
        let (controller, source) = try makeSource()
        let floating = try #require(source.floatFocusedPane())
        let pane = try #require(floating.split.focusedPane)
        source.teardown()
        #expect(pane.didTeardown)
        #expect(source.floatingPanels.isEmpty)
        controller.window?.close()
    }

    @Test func floatingPanesRemainInSavedLayout() throws {
        let (controller, source) = try makeSource()
        defer { stop(controller, source) }
        let floating = try #require(source.floatFocusedPane())
        let state = try #require(source.windowState(frame: controller.window!.frame))
        guard case .split = state.layout else {
            Issue.record("Floating pane must remain in the restorable split layout")
            return
        }
        floating.close()
        #expect(source.floatingPanels.isEmpty)
        let closedState = try #require(source.windowState(frame: controller.window!.frame))
        guard case .pane = closedState.layout else {
            Issue.record("Closing the float must remove it from the restorable layout")
            return
        }
    }
}
