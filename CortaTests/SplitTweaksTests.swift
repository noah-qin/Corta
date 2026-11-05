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

/// `auto-balance-panes`, `focus-follows-mouse`, `best-fit-split`.
@MainActor
@Suite(.serialized)
struct SplitTweaksTests {
    // MARK: - Shares

    private func leaf() -> NSView { NSView(frame: .zero) }

    @Test func threeInARowEachGetAThirdNotAHalfAndTwoQuarters() throws {
        let first = leaf(), second = leaf()
        let tree = SplitTree(root: first)
        let outer = tree.split(leaf: first, orientation: .columns, newLeaf: second)
        tree.split(leaf: second, orientation: .columns, newLeaf: leaf())
        outer.frame = NSRect(x: 0, y: 0, width: 300 + 2 * outer.dividerThickness, height: 100)
        #expect(SplitTree.shares(of: outer, vertical: true) == 3)
        #expect(try #require(SplitTree.balancedPosition(of: outer)) == 100)
    }

    @Test func aStackCountsAsItsWidestMemberAcrossTheAxis() {
        let first = leaf(), second = leaf()
        let tree = SplitTree(root: first)
        let outer = tree.split(leaf: first, orientation: .columns, newLeaf: second)
        tree.split(leaf: second, orientation: .rows, newLeaf: leaf())
        #expect(SplitTree.shares(of: outer, vertical: true) == 2)
        #expect(SplitTree.shares(of: outer, vertical: false) == 2)
    }

    // MARK: - Best fit

    @Test func bestFitSplitsAlongTheLongerSide() {
        let minimum = CGSize(width: 100, height: 100)
        #expect(BestFitSplit.orientation(size: CGSize(width: 800, height: 400), minimum: minimum, gap: 4) == .columns)
        #expect(BestFitSplit.orientation(size: CGSize(width: 400, height: 800), minimum: minimum, gap: 4) == .rows)
    }

    @Test func bestFitTakesTheOtherWayWhenTheLongerSideCannotFit() {
        func fit(_ width: CGFloat, _ height: CGFloat, minimum: CGSize) -> SplitOrientation? {
            BestFitSplit.orientation(size: CGSize(width: width, height: height), minimum: minimum, gap: 4)
        }
        #expect(fit(900, 800, minimum: CGSize(width: 500, height: 100)) == .rows)
        #expect(fit(500, 900, minimum: CGSize(width: 100, height: 500)) == .columns)
        #expect(fit(100, 300, minimum: CGSize(width: 100, height: 200)) == nil)
    }

    // MARK: - Focus follows the mouse

    private var allowed: FocusFollowsMouse {
        FocusFollowsMouse(
            enabled: true, pointerMoved: true, windowHasKeyboard: true, buttonPressed: false,
            trackingMenu: false, modalShowing: false, terminalHasKeyboard: true, composing: false,
            targetCanTakeFocus: true)
    }

    @Test func thePointerEnteringFocusesWhenNothingStandsInTheWay() {
        #expect(allowed.shouldFocus)
    }

    @Test func aPointerNotYetSeenHasNotMoved() {
        let here = NSPoint(x: 10, y: 10)
        #expect(!FocusFollowsMouse.pointerMoved(from: nil, to: here))
        #expect(!FocusFollowsMouse.pointerMoved(from: here, to: here))
        #expect(FocusFollowsMouse.pointerMoved(from: NSPoint(x: 11, y: 10), to: here))
    }

    @Test func eachRequirementStopsItWhenFalse() {
        let required: [WritableKeyPath<FocusFollowsMouse, Bool>] = [
            \.enabled, \.pointerMoved, \.windowHasKeyboard, \.terminalHasKeyboard, \.targetCanTakeFocus,
        ]
        for path in required {
            var rule = allowed
            rule[keyPath: path] = false
            #expect(!rule.shouldFocus, "\(path)")
        }
    }

    @Test func eachInterruptionStopsItWhenTrue() {
        let interruptions: [WritableKeyPath<FocusFollowsMouse, Bool>] = [
            \.buttonPressed, \.trackingMenu, \.modalShowing, \.composing,
        ]
        for path in interruptions {
            var rule = allowed
            rule[keyPath: path] = true
            #expect(!rule.shouldFocus, "\(path)")
        }
    }

    // MARK: - Defaults, and off means as before

    @Test func allThreeAreOffByDefault() {
        let configuration = Configuration()
        #expect(!configuration.autoBalancePanes)
        #expect(!configuration.focusFollowsMouse)
        #expect(!configuration.bestFitSplit)
    }

    /// Runs `body` with one flag on, in the test host's throwaway stage.
    private func with(
        _ flag: WritableKeyPath<Configuration, Bool>, _ body: () throws -> Void
    ) throws {
        let store = ConfigurationStore.shared
        _ = store.update { $0[keyPath: flag] = true }
        defer { _ = store.update { $0[keyPath: flag] = false } }
        try body()
    }

    private func makeWindow() -> (SplitViewController, NSWindow) {
        let split = SplitViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = split
        _ = split.view
        // A content view controller sizes the window to its view; these rules
        // are about room, so give it some back.
        window.setContentSize(NSSize(width: 1200, height: 600))
        split.view.layoutSubtreeIfNeeded()
        return (split, window)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func offASecondSplitHalvesTheFocusedPaneAsEver() throws {
        let (split, window) = makeWindow()
        defer { split.teardown() }
        split.splitFocusedPane(orientation: .columns)
        split.splitTransition.finish()
        split.splitFocusedPane(orientation: .columns)
        split.splitTransition.finish()
        split.view.layoutSubtreeIfNeeded()
        let widths = split.tree.leaves.map(\.frame.width)
        #expect(abs(widths[1] - widths[2]) < 2)
        #expect(widths[0] > widths[1] * 1.5, "half, then a half of the half")
        _ = window
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func onThreePanesInARowAreEqualAndClosingRebalances() throws {
        try with(\.autoBalancePanes) {
            let (split, window) = makeWindow()
            defer { split.teardown() }
            split.splitFocusedPane(orientation: .columns)
            split.splitFocusedPane(orientation: .columns)
            split.view.layoutSubtreeIfNeeded()
            var widths = split.tree.leaves.map(\.frame.width)
            #expect(abs(widths[0] - widths[1]) < 2 && abs(widths[1] - widths[2]) < 2, "\(widths)")
            let last = try #require(split.focusedPane)
            split.closePane(last)
            split.view.layoutSubtreeIfNeeded()
            widths = split.tree.leaves.map(\.frame.width)
            #expect(abs(widths[0] - widths[1]) < 2, "\(widths)")
            _ = window
        }
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aPlacedDividerStaysUntilEqualize() throws {
        try with(\.autoBalancePanes) {
            let (split, window) = makeWindow()
            defer { split.teardown() }
            split.splitFocusedPane(orientation: .columns)
            let root = try #require(split.tree.root as? PaneSplitView)
            root.setPosition(root.bounds.width * 0.7, ofDividerAt: 0)
            root.isUserPositioned = true
            split.view.layoutSubtreeIfNeeded()
            let placed = root.subviews[0].frame.width

            split.splitFocusedPane(orientation: .rows)
            split.view.layoutSubtreeIfNeeded()
            #expect(abs(root.subviews[0].frame.width - placed) < 2)

            split.equalizePanes(nil)
            #expect(!root.isUserPositioned)
            _ = window
        }
    }

    /// A move opens and closes places as a split and a close do.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aMoveRebalancesWhenBalancingIsOn() throws {
        try with(\.autoBalancePanes) {
            let (split, window) = makeWindow()
            defer { split.teardown() }
            split.splitFocusedPane(orientation: .columns)
            split.splitFocusedPane(orientation: .rows)
            split.view.layoutSubtreeIfNeeded()
            split.movePaneLeft(nil)
            split.view.layoutSubtreeIfNeeded()
            let widths = split.tree.leaves.map(\.frame.width)
            #expect(widths.count == 3)
            #expect(abs(widths[0] - widths[1]) < 2 && abs(widths[1] - widths[2]) < 2, "\(widths)")
            _ = window
        }
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func equalizeWhileZoomedKeepsAPlacedDividerMarked() throws {
        let (split, window) = makeWindow()
        defer { split.teardown() }
        split.splitFocusedPane(orientation: .columns)
        split.splitTransition.finish()
        let root = try #require(split.tree.root as? PaneSplitView)
        root.isUserPositioned = true
        split.zoomFocusedPane()
        split.equalizePanes(nil)
        #expect(root.isUserPositioned)
        _ = window
    }

    /// Closing took the old node and its mark; the reopened divider earns it back.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aReopenedPlacedDividerCountsAsPlaced() throws {
        let (split, window) = makeWindow()
        defer { split.teardown() }
        split.splitFocusedPane(orientation: .columns)
        split.splitTransition.finish()
        let root = try #require(split.tree.root as? PaneSplitView)
        root.setPosition(root.bounds.width * 0.7, ofDividerAt: 0)
        split.view.layoutSubtreeIfNeeded()
        split.closePane(try #require(split.focusedPane))
        split.view.layoutSubtreeIfNeeded()
        split.reopenClosedPane(nil)
        split.splitTransition.finish()
        let reopened = try #require(split.tree.root as? PaneSplitView)
        #expect(reopened.isUserPositioned)
        _ = window
    }

    /// A restored layout is rebuilt through `splitFocusedPane` and comes back
    /// as saved, with its uneven divider counted as placed.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func restoringIsNotRebalanced() throws {
        try with(\.autoBalancePanes) {
            let (split, window) = makeWindow()
            defer { split.teardown() }
            let pane = PaneLayout.pane(directory: nil, presetName: nil, isFocused: false)
            split.restore(layout: .split(vertical: true, position: 0.7, first: pane, second: pane))
            split.view.layoutSubtreeIfNeeded()
            let root = try #require(split.tree.root as? PaneSplitView)
            #expect(abs(root.subviews[0].frame.width / root.bounds.width - 0.7) < 0.02)
            #expect(root.isUserPositioned)
            _ = window
        }
    }

    @Test func aRecentBestFitLeavesThePaletteWithItsKey() throws {
        let model = CommandPaletteModel(agents: { [] })
        try with(\.bestFitSplit) {
            model.query = TerminalCommand.splitBestFit.title
            #expect(model.selectedCommand == .splitBestFit)
            model.runSelected()
            model.query = ""
            #expect(model.rows.compactMap(\.command).contains(.splitBestFit))
        }
        model.rebuildRows()
        #expect(!model.rows.compactMap(\.command).contains(.splitBestFit))
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func theBestFitCommandIsOffUntilItsKeyIsOn() throws {
        let item = NSMenuItem(title: "", action: TerminalCommand.splitBestFit.action, keyEquivalent: "")
        let (split, window) = makeWindow()
        defer { split.teardown() }
        #expect(!split.validateMenuItem(item))
        split.splitBestFit(nil)
        #expect(split.panes.count == 1)
        #expect(!TerminalCommand.splitBestFit.isOfferedInPalette)
        try with(\.bestFitSplit) {
            #expect(split.validateMenuItem(item))
            #expect(TerminalCommand.splitBestFit.isOfferedInPalette)
            split.splitBestFit(nil)
            #expect(split.panes.count == 2)
            let root = try #require(split.tree.root as? NSSplitView)
            #expect(root.isVertical, "wider than tall")
        }
        _ = window
    }

    /// ⌘D and ⇧⌘D keep their direction whatever the key says.
    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func theSplitCommandsDoNotChangeWithTheKeyOn() throws {
        try with(\.bestFitSplit) {
            let (split, window) = makeWindow()
            defer { split.teardown() }
            split.splitDown(nil)
            split.splitTransition.finish()
            let root = try #require(split.tree.root as? NSSplitView)
            #expect(!root.isVertical, "a wide pane still splits down")
            _ = window
        }
    }
}
