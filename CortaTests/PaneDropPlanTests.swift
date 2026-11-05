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
import CoreGraphics
import Testing
@testable import Corta

/// The drop target, with no window: every edge, the middle and the invalid
/// spots, at the sizes that change the answer. y is up.
@MainActor
struct PaneDropPlanTests {
    private typealias Plan = PaneDropPlan
    private let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
    private let small = CGSize(width: 100, height: 60)

    private func target(_ x: CGFloat, _ y: CGFloat, dragged: String? = nil) -> Plan.Target<String> {
        Plan.target(at: CGPoint(x: x, y: y), panes: [(id: "a", frame: frame)], dragged: dragged, minimum: small)
    }

    @Test func eachEdgeAndTheMiddle() {
        #expect(target(105, 250) == .edge("a", .left))
        #expect(target(495, 250) == .edge("a", .right))
        #expect(target(300, 395) == .edge("a", .up))
        #expect(target(300, 105) == .edge("a", .down))
        #expect(target(300, 250) == .center("a"))
    }

    @Test func aCornerGoesToTheNearerEdge() {
        #expect(target(102, 390) == .edge("a", .left))
        #expect(target(110, 398) == .edge("a", .up))
    }

    @Test func nowhereIsNothing() {
        #expect(target(50, 50) == .none)
        #expect(target(300, 250, dragged: "a") == .none, "onto itself")
        #expect(target(105, 250, dragged: "a") == .none)
        #expect(Plan.target(at: .zero, panes: [(id: "a", frame: .zero)], dragged: nil, minimum: small) == .none)
    }

    @Test func theRightPaneAmongSeveral() {
        let panes: [(id: String, frame: CGRect)] = [
            ("left", CGRect(x: 0, y: 0, width: 200, height: 200)),
            ("right", CGRect(x: 208, y: 0, width: 200, height: 200)),
        ]
        func at(_ x: CGFloat) -> Plan.Target<String> {
            Plan.target(at: CGPoint(x: x, y: 100), panes: panes, dragged: "left", minimum: small)
        }
        #expect(at(100) == .none)
        #expect(at(204) == .none, "the gap between panes is neither")
        #expect(at(212) == .edge("right", .left))
        #expect(at(308) == .center("right"))
    }

    @Test(arguments: [
        (CGFloat(100), CGFloat(36)), (CGFloat(50), CGFloat(25)),
        (CGFloat(400), CGFloat(100)), (CGFloat(250), CGFloat(70)),
    ])
    func edgeDepthKeepsToItsBounds(side: CGFloat, depth: CGFloat) {
        #expect(Plan.edgeDepth(ofSide: side) == depth)
    }

    @Test func anEdgeWithNoRoomFallsToTheMiddle() {
        let narrow = CGRect(x: 0, y: 0, width: 150, height: 400)
        func at(_ x: CGFloat, _ y: CGFloat) -> Plan.Target<String> {
            Plan.target(at: CGPoint(x: x, y: y), panes: [(id: "a", frame: narrow)], dragged: nil,
                minimum: CGSize(width: 100, height: 60), gap: 8)
        }
        #expect(at(5, 200) == .center("a"), "two halves of 71 are under 100")
        #expect(at(75, 395) == .edge("a", .up), "the other axis has room")
    }

    @Test func previewIsTheHalfItWouldTake() {
        #expect(Plan.previewFrame(of: frame, direction: .left) == CGRect(x: 100, y: 100, width: 200, height: 300))
        #expect(Plan.previewFrame(of: frame, direction: .right) == CGRect(x: 300, y: 100, width: 200, height: 300))
        #expect(Plan.previewFrame(of: frame, direction: .up) == CGRect(x: 100, y: 250, width: 400, height: 150))
        #expect(Plan.previewFrame(of: frame, direction: .down) == CGRect(x: 100, y: 100, width: 400, height: 150))
    }
}

/// The same running panes in new places, through a real window.
@MainActor
@Suite(.serialized)
struct PaneDragTests {
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

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func anEdgeMovesItAndTheSessionStays() throws {
        let controller = makeWindow(panes: 3)
        defer { close(controller) }
        let split = try #require(controller.selectedTab?.split)
        let (first, last) = (split.panes[0], split.panes[2])
        let sessions = split.panes.map(\.session)
        split.noteFocus(first)
        split.moveFocusedPane(beside: last, direction: .down)
        #expect(split.panes.map(\.session).allSatisfy { session in sessions.contains { $0 === session } })
        #expect(first.view.superview === last.view.superview)
        let parent = try #require(first.view.superview as? NSSplitView)
        #expect(!parent.isVertical)
        #expect(parent.subviews == [last.view, first.view])
        #expect(split.focusedPane === first)
        #expect(controller.window?.firstResponder === first.terminalView)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func alreadyThereChangesNothing() throws {
        let controller = makeWindow()
        defer { close(controller) }
        let split = try #require(controller.selectedTab?.split)
        let (first, second) = (split.panes[0], split.panes[1])
        split.noteFocus(first)
        let frames = (first.view.frame, second.view.frame)
        let root = split.tree.root
        split.moveFocusedPane(beside: second, direction: .left)
        #expect(split.tree.root === root)
        #expect(first.view.frame == frames.0)
        #expect(second.view.frame == frames.1)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func theMiddleSwapsAcrossTabsEachTakingTheTabsFont() throws {
        let controller = makeWindow()
        defer { close(controller) }
        let source = try #require(controller.selectedTab)
        let pane = try #require(source.split.panes.first)
        let keeper = try #require(source.split.panes.last)
        controller.addTab(setup: .init())
        let target = try #require(controller.selectedTab)
        let other = try #require(target.split.panes.first)
        controller.selectTab(source)
        source.split.noteFocus(pane)
        let (paneSession, otherSession) = (pane.session, other.session)

        source.split.swapFocusedPane(with: other)

        #expect(pane.session === paneSession && other.session === otherSession)
        #expect(target.split.panes == [pane])
        #expect(Set(source.split.panes.map(ObjectIdentifier.init))
            == [ObjectIdentifier(other), ObjectIdentifier(keeper)])
        #expect(target.split.tree.root === pane.view)
        #expect(controller.selectedTab === target)
        #expect(controller.window?.firstResponder === pane.terminalView)
        #expect(source.split.focusedPane === other)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func theLastPaneLeavingATabClosesIt() throws {
        let controller = makeWindow(panes: 1)
        defer { close(controller) }
        let source = try #require(controller.selectedTab)
        let pane = try #require(source.split.panes.first)
        controller.addTab(setup: .init())
        let target = try #require(controller.selectedTab)
        let anchor = try #require(target.split.panes.first)
        controller.selectTab(source)
        source.split.noteFocus(pane)
        source.split.moveFocusedPane(beside: anchor, direction: .left)
        #expect(controller.tabs.count == 1)
        #expect(target.split.panes.first === pane)
        #expect((pane.view.superview as? NSSplitView)?.subviews.first === pane.view)
    }

    // MARK: - The session, without an event loop

    private func point(in view: NSView, _ x: CGFloat, _ y: CGFloat) -> NSPoint {
        view.convert(NSPoint(x: view.bounds.width * x, y: view.bounds.height * y), to: nil)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aPreviewChangesNothingAndACancelGoesBack() throws {
        let controller = makeWindow()
        defer { close(controller) }
        let source = try #require(controller.selectedTab)
        let (pane, other) = (source.split.panes[0], source.split.panes[1])
        controller.addTab(setup: .init())
        controller.selectTab(source)
        source.split.noteFocus(pane)
        let frames = source.split.panes.map(\.view.frame)
        let session = try #require(PaneDragSession(pane: pane, controller: controller))
        session.begin()
        session.update(atWindowPoint: point(in: other.view, 0.5, 0.5))
        let otherID = ObjectIdentifier(other)
        #expect(session.over == .pane(.center(otherID)))
        session.update(atWindowPoint: point(in: other.view, 0.98, 0.5))
        #expect(session.over == .pane(.edge(otherID, .right)))
        session.update(atWindowPoint: point(in: pane.view, 0.5, 0.5))
        #expect(session.over == .nothing)
        // A dwell on the other tab shows it; the cancel returns.
        let strip = controller.tabStrip
        strip.layoutSubtreeIfNeeded()
        if let tab = strip.tabView(at: 1) {
            let over = tab.convert(NSPoint(x: tab.bounds.midX, y: tab.bounds.midY), to: nil)
            session.update(atWindowPoint: over, now: 100)
            #expect(session.over == .tab(controller.tabs[1].id))
            #expect(controller.selectedTab === source)
            session.update(atWindowPoint: over, now: 101)
            #expect(controller.selectedTab === controller.tabs[1])
        }
        session.cancel()
        #expect(controller.selectedTab === source)
        #expect(source.split.panes.map(\.view.frame) == frames)
        #expect(controller.window?.firstResponder === pane.terminalView)
        #expect(pane.view.window?.contentView?.subviews.contains { $0 is PaneDropPreviewView } == false)
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func thePreviewShowsWhatTheDropWouldReallyDo() throws {
        let controller = makeWindow()
        defer { close(controller) }
        let split = try #require(controller.selectedTab?.split)
        let (pane, other) = (split.panes[0], split.panes[1])
        split.noteFocus(pane)
        let session = try #require(PaneDragSession(pane: pane, controller: controller))
        session.begin()
        defer { session.cancel() }
        session.update(atWindowPoint: point(in: other.view, 0.02, 0.5))
        #expect(session.over == .nothing, "already on that side")
        #expect(session.previewFrame == nil)
        session.update(atWindowPoint: point(in: other.view, 0.5, 0.02))
        let content = try #require(controller.window?.contentView)
        let whole = try #require(pane.view.superview).convert(try #require(pane.view.superview).bounds, to: content)
        let shown = try #require(session.previewFrame)
        #expect(abs(shown.width - (whole.width - 4)) <= 1, "both panes' width: the other pane grows as this one leaves")
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aZoomedPaneInAnotherTabCanOnlySwap() throws {
        let controller = makeWindow(panes: 1)
        defer { close(controller) }
        let source = try #require(controller.selectedTab)
        let pane = try #require(source.split.panes.first)
        controller.addTab(setup: .init())
        let target = try #require(controller.selectedTab)
        target.split.splitFocusedPane(orientation: .columns)
        target.split.splitTransition.finish()
        target.split.toggleZoomPane(nil)
        let zoomed = try #require(target.split.zoomedPane)
        let session = try #require(PaneDragSession(pane: pane, controller: controller))
        session.begin()
        session.update(atWindowPoint: point(in: zoomed.view, 0.98, 0.5))
        #expect(session.over == .pane(.center(ObjectIdentifier(zoomed))))
        #expect(target.split.zoomedPane === zoomed, "nothing unzooms before a drop")
        session.cancel()
    }

    @Test(.enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
    func aZoomedPaneHasNoPaneToLandOn() throws {
        let controller = makeWindow()
        defer { close(controller) }
        let split = try #require(controller.selectedTab?.split)
        let pane = try #require(split.panes.first)
        split.noteFocus(pane)
        split.toggleZoomPane(nil)
        let session = try #require(PaneDragSession(pane: pane, controller: controller))
        session.begin()
        session.update(atWindowPoint: point(in: pane.view, 0.9, 0.5))
        #expect(session.over == .nothing)
        session.finish()
        #expect(split.zoomedPane === pane, "nothing moved, so nothing unzoomed")
    }
}
