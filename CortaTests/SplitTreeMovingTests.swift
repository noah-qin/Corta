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

/// `SplitTree`'s rearranging, with plain views: where each leaf ends up, and
/// which nodes survive to keep their dividers.
@MainActor
struct SplitTreeMovingTests {
    private func leaf(_ name: String) -> NSView {
        let view = NSView(frame: .zero)
        view.identifier = NSUserInterfaceItemIdentifier(name)
        return view
    }

    /// `(A|B)` for columns, `(A/B)` for rows.
    private func shape(_ view: NSView) -> String {
        guard let split = view as? NSSplitView else { return view.identifier?.rawValue ?? "?" }
        let separator = split.isVertical ? "|" : "/"
        return "(" + split.subviews.map(shape).joined(separator: separator) + ")"
    }

    /// A tree laid out in a real frame, so geometric neighbours exist.
    private func settle(_ tree: SplitTree) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        tree.root.frame = container.bounds
        container.addSubview(tree.root)
        func lay(_ view: NSView) {
            guard let split = view as? NSSplitView else { return }
            split.adjustSubviews()
            let axis = split.isVertical ? split.bounds.width : split.bounds.height
            split.setPosition(axis / 2, ofDividerAt: 0)
            split.layoutSubtreeIfNeeded()
            for child in split.subviews { lay(child) }
        }
        lay(tree.root)
        return container
    }

    /// A tree and its leaves by name.
    private struct Fixture {
        let tree: SplitTree
        let named: [String: NSView]
        subscript(name: String) -> NSView { named[name]! }
    }

    /// `A | B`.
    private func two() -> Fixture {
        let first = leaf("A"), second = leaf("B")
        let tree = SplitTree(root: first)
        tree.split(leaf: first, orientation: .columns, newLeaf: second)
        return Fixture(tree: tree, named: ["A": first, "B": second])
    }

    /// `A | (B / C)`.
    private func stack() -> Fixture {
        let base = two()
        let third = leaf("C")
        base.tree.split(leaf: base["B"], orientation: .rows, newLeaf: third)
        return Fixture(tree: base.tree, named: base.named.merging(["C": third]) { $1 })
    }

    /// `A | B | C`, written `first | (second | third)` or `(first | second) | third`.
    private func three(_ make: (SplitTree, NSView, NSView, NSView) -> Void) -> Fixture {
        let first = leaf("A"), second = leaf("B"), third = leaf("C")
        let tree = SplitTree(root: first)
        make(tree, first, second, third)
        return Fixture(tree: tree, named: ["A": first, "B": second, "C": third])
    }

    @Test func movingPastASingleNeighbourExchangesPlaces() {
        let fixture = two(), tree = fixture.tree
        let container = settle(tree)
        #expect(tree.move(leaf: fixture["B"], direction: .left, inContainer: container))
        #expect(shape(tree.root) == "(B|A)")
        #expect(tree.move(leaf: fixture["B"], direction: .right, inContainer: container))
        #expect(shape(tree.root) == "(A|B)")
    }

    @Test func movingAcrossTheOnlySplitTurnsIt() {
        let fixture = two(), tree = fixture.tree
        let container = settle(tree)
        #expect(tree.move(leaf: fixture["B"], direction: .up, inContainer: container))
        #expect(shape(tree.root) == "(B/A)")
        #expect(tree.move(leaf: fixture["B"], direction: .right, inContainer: container))
        #expect(shape(tree.root) == "(A|B)")
        #expect(tree.move(leaf: fixture["B"], direction: .down, inContainer: container))
        #expect(shape(tree.root) == "(A/B)")
    }

    @Test func atTheEdgeNothingChanges() {
        let fixture = two(), tree = fixture.tree
        let container = settle(tree)
        let root = tree.root
        #expect(!tree.move(leaf: fixture["A"], direction: .left, inContainer: container))
        #expect(!tree.move(leaf: fixture["B"], direction: .right, inContainer: container))
        #expect(tree.root === root)
        #expect(shape(tree.root) == "(A|B)")
    }

    @Test func aLonePaneHasNowhereToGo() {
        let a = leaf("A")
        let tree = SplitTree(root: a)
        #expect(!tree.move(leaf: a, direction: .left, inContainer: NSView()))
        #expect(tree.root === a)
    }

    @Test func aPaneLeavesAStackToStandBesideWhatRemains() {
        let fixture = stack(), tree = fixture.tree
        let container = settle(tree)
        #expect(tree.move(leaf: fixture["B"], direction: .left, inContainer: container))
        #expect(shape(tree.root) == "(A|(B|C))")
    }

    @Test func movingRightOutOfAStackLandsOnTheRight() {
        let fixture = stack(), tree = fixture.tree
        let container = settle(tree)
        #expect(tree.move(leaf: fixture["B"], direction: .right, inContainer: container))
        #expect(shape(tree.root) == "(A|(C|B))")
    }

    /// `A | (B / C)`, A moving right: it joins the stack beside the nearest
    /// pane, then a second press takes it out the far side.
    @Test func aPaneJoinsAStackAndCanLeaveIt() throws {
        let fixture = stack(), tree = fixture.tree
        let container = settle(tree)
        let moving = fixture["A"]
        #expect(tree.move(leaf: moving, direction: .right, inContainer: container))
        #expect(tree.leafCount == 3)
        #expect(try #require(tree.root as? NSSplitView).isVertical == false, "the stack is now the whole tree")
        tree.root.frame = container.bounds
        #expect(tree.move(leaf: moving, direction: .right, inContainer: container))
        #expect(try #require(tree.root as? NSSplitView).isVertical)
        #expect(tree.root.subviews[1] === moving, "A takes the right edge")
    }

    /// Nested same-axis splits read as one row.
    @Test func aRowNestedInTheSameAxisStepsOnePlace() {
        let fixture = three { tree, first, second, third in
            tree.split(leaf: first, orientation: .columns, newLeaf: second)
            tree.split(leaf: second, orientation: .columns, newLeaf: third)
        }
        let tree = fixture.tree, moving = fixture["A"]
        let container = settle(tree)
        #expect(shape(tree.root) == "(A|(B|C))")
        #expect(tree.move(leaf: moving, direction: .right, inContainer: container))
        #expect(shape(tree.root) == "(B|(A|C))")
        #expect(tree.move(leaf: moving, direction: .right, inContainer: container))
        #expect(shape(tree.root) == "(B|(C|A))")
        #expect(!tree.move(leaf: moving, direction: .right, inContainer: container))
    }

    /// `(A | B) / C`, B moving right: past its row's end, out to the tree's edge.
    @Test func theEndOfANestedRowLeavesForTheEdge() {
        let fixture = three { tree, first, second, third in
            tree.split(leaf: first, orientation: .rows, newLeaf: third)
            tree.split(leaf: first, orientation: .columns, newLeaf: second)
        }
        let tree = fixture.tree
        let container = settle(tree)
        #expect(shape(tree.root) == "((A|B)/C)")
        #expect(tree.move(leaf: fixture["B"], direction: .right, inContainer: container))
        #expect(shape(tree.root) == "((A/C)|B)")
    }

    @Test func aMoveKeepsEveryNodeBinaryAndEveryLeaf() {
        let fixture = stack(), tree = fixture.tree
        let container = settle(tree)
        let all = Set(fixture.named.values.map(ObjectIdentifier.init))
        for direction in [SplitMoveDirection.left, .up, .right, .down, .left, .left, .down, .right] {
            tree.move(leaf: fixture["B"], direction: direction, inContainer: container)
            tree.root.frame = container.bounds
            #expect(Set(tree.leaves.map(ObjectIdentifier.init)) == all)
            #expect(tree.nodes.allSatisfy { $0.subviews.count == 2 })
        }
    }

    @Test func swapExchangesPlacesAndKeepsTheShape() {
        let fixture = stack(), tree = fixture.tree
        _ = settle(tree)
        let firstFrame = fixture["A"].frame
        let secondFrame = fixture["C"].frame
        tree.swap(fixture["A"], fixture["C"])
        #expect(shape(tree.root) == "(C|(B/A))")
        #expect(fixture["C"].frame == firstFrame)
        #expect(fixture["A"].frame == secondFrame)
    }

    @Test func swapWithinOneNodeReversesIt() {
        let fixture = two(), tree = fixture.tree
        let node = tree.root
        tree.swap(fixture["A"], fixture["B"])
        #expect(tree.root === node)
        #expect(shape(tree.root) == "(B|A)")
    }

    @Test func dividerFractionsAreReadByNode() throws {
        let tree = stack().tree
        _ = settle(tree)
        let root = try #require(tree.root as? NSSplitView)
        root.setPosition(250, ofDividerAt: 0)
        root.layoutSubtreeIfNeeded()
        let fractions = tree.dividerFractions()
        #expect(fractions.count == 2)
        #expect(abs(try #require(fractions[ObjectIdentifier(root)]) - 0.25) < 0.01)
    }
}
