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

/// Moving a running pane: real panes in a real window, because what can go
/// wrong is a process restarting or a view left in the wrong place.
@MainActor
@Suite(.serialized)
struct PaneMoveTests {
    private func makeWindow(panes: Int = 2) -> TerminalWindowController {
        let controller = TerminalWindowController(setup: .init())
        controller.showWindow(nil)
        controller.window?.makeKey()
        let split = controller.selectedTab!.split
        split.view.layoutSubtreeIfNeeded()
        for _ in 1..<max(panes, 1) { split.splitFocusedPane(orientation: .columns); split.splitTransition.finish() }
        return controller
    }

    private func close(_ controller: TerminalWindowController) {
        for tab in controller.tabs { tab.split.teardown() }
        controller.window?.close()
    }

    /// `pane` is alive, focused, parented where it is shown, and has the keyboard.
    private func expectFocused(
        _ pane: ViewController, session: TerminalSession?, in split: SplitViewController,
        window: NSWindow?, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(pane.session === session, sourceLocation: sourceLocation)
        #expect(pane.parent === split, sourceLocation: sourceLocation)
        #expect(split.focusedPane === pane, sourceLocation: sourceLocation)
        #expect(pane.view.isDescendant(of: split.view), sourceLocation: sourceLocation)
        #expect(split.tree.leaves.contains(pane.view), sourceLocation: sourceLocation)
        #expect(window?.firstResponder === pane.terminalView, sourceLocation: sourceLocation)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func movingWithinATabKeepsTheSessionAndTheKeyboard() throws {
        let controller = makeWindow()
        defer { close(controller) }
        let split = try #require(controller.selectedTab?.split)
        let pane = try #require(split.focusedPane)
        let session = pane.session
        let other = try #require(split.panes.first { $0 !== pane })
        let otherSession = other.session

        split.movePaneLeft(nil)

        #expect(split.tree.leaves == [pane.view, other.view])
        expectFocused(pane, session: session, in: split, window: controller.window)
        #expect(other.session === otherSession)
        #expect(split.panes.count == 2)
    }

    /// Equal columns before and after: the child hears nothing, and a selection
    /// stands; only a real change of columns rewraps and clears it.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func swappingEqualPanesSendsNoResizeAndKeepsTheSelection() throws {
        let controller = makeWindow()
        defer { close(controller) }
        let split = try #require(controller.selectedTab?.split)
        split.equalizePanes(nil)
        let pane = try #require(split.focusedPane)
        let other = try #require(split.panes.first { $0 !== pane })
        let size = pane.lastRequestedSize
        let otherSize = other.lastRequestedSize
        #expect(size?.columns == otherSize?.columns)
        let grid = try #require(pane.session?.snapshot())
        let selection = TerminalSelection(
            SelectionRange(
                anchor: SelectionPoint(row: 0, column: 0), head: SelectionPoint(row: 0, column: 2)),
            grid: grid)
        pane.selection = selection

        split.swapPaneLeft(nil)

        #expect(split.tree.leaves == [pane.view, other.view])
        #expect(pane.lastRequestedSize == size)
        #expect(other.lastRequestedSize == otherSize)
        #expect(pane.selection == selection)
    }

    /// A surviving divider stays where the user dragged it.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aMoveLeavesOtherDividersWhereTheyWere() throws {
        let controller = makeWindow()
        defer { close(controller) }
        let split = try #require(controller.selectedTab?.split)
        let right = try #require(split.focusedPane)
        split.splitFocusedPane(orientation: .rows)
        split.splitTransition.finish()
        let root = try #require(split.tree.root as? NSSplitView)
        root.setPosition(root.bounds.width * 0.6, ofDividerAt: 0)
        split.view.layoutSubtreeIfNeeded()
        let share = root.subviews[0].frame.width / root.bounds.width
        // `right`, the stack's top pane, goes to the tree's top edge; the node
        // the drag set is now the lower half, its share intact.
        split.takeFocus(right)
        split.movePaneUp(nil)
        split.view.layoutSubtreeIfNeeded()
        #expect(split.tree.root !== root)
        #expect(split.tree.root.subviews.contains(root))
        #expect(abs(root.subviews[0].frame.width / root.bounds.width - share) < 0.01)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func movingAZoomedPaneUnzoomsItFirst() throws {
        let controller = makeWindow()
        defer { close(controller) }
        let split = try #require(controller.selectedTab?.split)
        let pane = try #require(split.focusedPane)
        split.toggleZoomPane(nil)
        #expect(split.isPaneZoomed)

        split.movePaneLeft(nil)

        #expect(!split.isPaneZoomed)
        #expect(split.tree.leaves.first === pane.view)
        expectFocused(pane, session: pane.session, in: split, window: controller.window)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aPaneMovesToANewTabRunning() throws {
        let controller = makeWindow()
        defer { close(controller) }
        let source = try #require(controller.selectedTab)
        let pane = try #require(source.split.focusedPane)
        let session = pane.session
        let survivor = try #require(source.split.panes.first { $0 !== pane })

        source.split.movePaneToNewTab(nil)

        #expect(controller.tabs.count == 2)
        let tab = try #require(controller.selectedTab)
        #expect(tab !== source)
        #expect(tab.split.panes == [pane])
        expectFocused(pane, session: session, in: tab.split, window: controller.window)
        #expect(source.split.panes == [survivor])
        #expect(source.split.focusedPane === survivor)
        #expect(source.split.tree.root === survivor.view)
        #expect(pane.lastRequestedSize != nil)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aPaneMovesToAnExistingTabBehind() throws {
        let controller = makeWindow()
        defer { close(controller) }
        let source = try #require(controller.selectedTab)
        let target = controller.addTab(select: false)
        let pane = try #require(source.split.focusedPane)
        let session = pane.session
        let anchor = try #require(target.split.focusedPane)
        let anchorSession = anchor.session

        source.split.movePaneToNextTab(nil)

        #expect(controller.selectedTab === target)
        #expect(target.split.panes.count == 2)
        #expect(target.split.tree.leaves == [anchor.view, pane.view])
        #expect(anchor.session === anchorSession)
        expectFocused(pane, session: session, in: target.split, window: controller.window)
        #expect(source.split.panes.count == 1)
        #expect(controller.tabs.count == 2)
    }

    /// The tab's last pane goes, and the tab with it, without touching the pane.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func movingALastPaneClosesItsTab() throws {
        let controller = makeWindow(panes: 1)
        defer { close(controller) }
        let source = try #require(controller.selectedTab)
        let target = controller.addTab(select: false)
        let pane = try #require(source.split.focusedPane)
        let session = pane.session

        source.split.movePaneToNextTab(nil)

        #expect(controller.tabs.count == 1)
        #expect(controller.selectedTab === target)
        #expect(!pane.didTeardown)
        expectFocused(pane, session: session, in: target.split, window: controller.window)
    }

    /// One tab, one pane: every move command is disabled, and running one by
    /// key changes nothing.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aLonePaneInALoneTabHasNowhereToGo() throws {
        let controller = makeWindow(panes: 1)
        defer { close(controller) }
        let split = try #require(controller.selectedTab?.split)
        for command in [TerminalCommand.movePaneLeft, .swapPaneUp, .movePaneToNewTab, .movePaneToNextTab] {
            let item = NSMenuItem(title: "", action: command.action, keyEquivalent: "")
            #expect(!split.validateMenuItem(item), "\(command)")
        }
        let pane = try #require(split.focusedPane)
        split.movePaneToNewTab(nil)
        split.movePaneToNextTab(nil)
        split.movePaneLeft(nil)
        #expect(controller.tabs.count == 1)
        #expect(split.panes == [pane])
    }

    /// What is written for the next launch is the arrangement on screen.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func theSavedLayoutFollowsAMove() throws {
        let controller = makeWindow()
        defer { close(controller) }
        let split = try #require(controller.selectedTab?.split)
        let window = try #require(controller.window)
        split.movePaneUp(nil)
        let state = try #require(split.windowState(frame: window.frame))
        guard case .split(let vertical, _, let first, let second) = state.layout else {
            Issue.record("expected a split")
            return
        }
        #expect(!vertical)
        guard case .pane(_, _, let firstFocused) = first, case .pane(_, _, let secondFocused) = second else {
            Issue.record("expected two panes")
            return
        }
        #expect(firstFocused)
        #expect(!secondFocused)
    }

    /// A reopen record names a sibling. Within the tab it stands; a sibling that
    /// left for another tab takes the position with it.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func reopenClosedPaneFollowsItsSibling() throws {
        let controller = makeWindow(panes: 3)
        defer { close(controller) }
        let split = try #require(controller.selectedTab?.split)
        let closing = try #require(split.focusedPane)
        split.closePane(closing)
        #expect(split.canReopenClosedPane)
        let sibling = try #require(split.lastClosedPane?.sibling)

        split.takeFocus(sibling)
        split.movePaneLeft(nil)
        #expect(split.canReopenClosedPane, "still in this tree")
        split.reopenClosedPane(nil)
        #expect(split.panes.count == 3)
        split.closePane(try #require(split.focusedPane))

        let again = try #require(split.lastClosedPane?.sibling)
        split.takeFocus(again)
        split.movePaneToNewTab(nil)
        #expect(!split.canReopenClosedPane)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func anOpenSearchMovesWithThePane() throws {
        let controller = makeWindow()
        defer { close(controller) }
        let split = try #require(controller.selectedTab?.split)
        let pane = try #require(split.focusedPane)
        pane.search.show()
        #expect(pane.search.field != nil)

        split.movePaneToNewTab(nil)

        let field = try #require(pane.search.field)
        #expect(field.isDescendant(of: pane.view))
        #expect(pane.search.bar != nil)
        let editor = controller.window?.firstResponder as? NSText
        #expect(editor?.delegate === field, "the field keeps the keyboard")
    }

    /// The tab can outlive the pane it was made for: the setup must not keep
    /// a pane that has moved on or closed, with its scrollback, alive.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aNewTabDoesNotHoldOnToThePaneItAdopted() throws {
        let controller = makeWindow()
        defer { close(controller) }
        let split = try #require(controller.selectedTab?.split)
        let pane = try #require(split.focusedPane)

        split.movePaneToNewTab(nil)

        let adopter = try #require(pane.splitController)
        #expect(adopter !== split)
        #expect(adopter.setup.adopting == nil)
    }

    /// Nodes made by a move answer divider drags like a split's.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func nodesMadeByAMoveAreWired() throws {
        let controller = makeWindow()
        defer { close(controller) }
        let split = try #require(controller.selectedTab?.split)
        split.movePaneUp(nil)
        #expect(split.tree.nodes.allSatisfy { $0.delegate === split })
    }

    @Test func thePaletteOffersTheOtherTabsByName() {
        let target = CommandPaletteModel.PaneMoveTarget(id: "tab-1", title: "build")
        var moved: String?
        let model = CommandPaletteModel(agents: { [] }, paneMoveTargets: { [target] })
        model.onMovePane = { moved = $0 }
        model.query = "move pane to tab"
        let row = model.rows.first { $0.id == "move-pane-tab-1" }
        #expect(row != nil)
        model.select(row!)
        model.runSelected()
        #expect(moved == "tab-1")
    }
}

/// Moves to another tab that cannot happen.
extension PaneMoveTests {
    /// However the submenu is built, each row has an action: that is what
    /// validation disables, and a row without one looks available.
    @Test func everyMoveToTabRowHasAnAction() throws {
        let menu = try #require(NSApp.mainMenu)
        func find(_ menu: NSMenu) -> NSMenu? {
            for item in menu.items {
                guard let submenu = item.submenu else { continue }
                if submenu.title == L10n.text("menu.movePaneToTab") { return submenu }
                if let found = find(submenu) { return found }
            }
            return nil
        }
        let submenu = try #require(find(menu))
        submenu.delegate?.menuNeedsUpdate?(submenu)
        #expect(!submenu.items.isEmpty)
        #expect(submenu.items.allSatisfy { $0.action != nil })
    }

    /// The newcomer takes the target's font, so the target's minimum decides.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aPaneThatWouldNotFitAtTheTargetsFontStaysPut() throws {
        let controller = makeWindow(panes: 1)
        defer { close(controller) }
        let source = try #require(controller.selectedTab)
        let target = controller.addTab(select: false)
        let pane = try #require(source.split.focusedPane)
        let anchor = try #require(target.split.focusedPane)
        anchor.setFontSize(24)
        pane.setFontSize(10)
        let minimum = anchor.minimumContentSize
        #expect(pane.minimumContentSize.height < minimum.height * 0.7)
        controller.window?.setContentSize(NSSize(width: minimum.width * 1.5, height: minimum.height * 1.5))

        source.split.movePaneToNextTab(nil)

        #expect(pane.parent === source.split)
        #expect(controller.tabs.count == 2)
        #expect(target.split.panes.count == 1)
    }

    /// A refused move with nothing to measure leaves a search field its keyboard.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aRefusedMoveLeavesTheSearchFieldItsKeyboard() throws {
        let controller = makeWindow(panes: 1)
        defer { close(controller) }
        let source = try #require(controller.selectedTab)
        let target = controller.addTab(select: false)
        let pane = try #require(source.split.focusedPane)
        let anchor = try #require(target.split.focusedPane)
        controller.window?.setContentSize(anchor.minimumContentSize)
        pane.search.show()
        let field = try #require(pane.search.field)

        source.split.movePaneToNextTab(nil)

        #expect(pane.parent === source.split)
        let editor = controller.window?.firstResponder as? NSText
        #expect(editor?.delegate === field)
    }

    /// A move that cannot happen leaves the target zoomed and the keyboard here.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aRefusedMoveKeepsTheTargetsZoom() throws {
        let controller = makeWindow(panes: 1)
        defer { close(controller) }
        let source = try #require(controller.selectedTab)
        let target = controller.addTab(select: false)
        target.split.splitFocusedPane(orientation: .columns)
        target.split.splitTransition.finish()
        let anchor = try #require(target.split.focusedPane)
        target.split.zoomFocusedPane()
        #expect(target.split.zoomedPane === anchor)
        let pane = try #require(source.split.focusedPane)
        controller.window?.setContentSize(anchor.minimumContentSize)

        source.split.movePaneToNextTab(nil)

        #expect(pane.parent === source.split)
        #expect(target.split.zoomedPane === anchor)
        #expect(controller.selectedTab === source)
        #expect(controller.window?.firstResponder === pane.terminalView)
    }
}
