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

/// Rearranging a running tree: the same leaf views in new places, nothing
/// recreated (`SplitViewController+Moving.swift` owns the panes). Divider
/// positions are the caller's to restore: AppKit re-halves a split that
/// loses a subview, so they are read before and written after.
extension SplitTree {
    /// Every internal node, parents before their children.
    var nodes: [NSSplitView] {
        var result: [NSSplitView] = []
        func walk(_ view: NSView) {
            guard let split = view as? NSSplitView else { return }
            result.append(split)
            for child in split.subviews { walk(child) }
        }
        walk(root)
        return result
    }

    /// Each node's divider as a share of its axis, by node identity: a node
    /// that survives keeps its share, and a new one has none.
    func dividerFractions() -> [ObjectIdentifier: Double] {
        var fractions: [ObjectIdentifier: Double] = [:]
        for node in nodes where node.subviews.count == 2 {
            let axis = node.isVertical ? node.bounds.width : node.bounds.height
            let first = node.isVertical ? node.subviews[0].frame.width : node.subviews[0].frame.height
            if axis > 0 { fractions[ObjectIdentifier(node)] = Double(first / axis) }
        }
        return fractions
    }

    /// Exchanges two leaves' places. The places keep their sizes.
    func swap(_ first: NSView, _ second: NSView) {
        guard first !== second, let firstParent = first.superview as? NSSplitView,
            let secondParent = second.superview as? NSSplitView
        else { return }
        let firstFrame = first.frame
        let secondFrame = second.frame
        let placeholder = NSView(frame: firstFrame)
        firstParent.replaceSubview(first, with: placeholder)
        secondParent.replaceSubview(second, with: first)
        firstParent.replaceSubview(placeholder, with: second)
        first.frame = secondFrame
        second.frame = firstFrame
    }

    /// Moves `leaf` one step in `direction`, reading the same-axis splits along
    /// its path as one row. Returns false when it is already as far as it
    /// goes, and changes nothing. In order, the rule:
    ///
    /// 1. In a split across the direction (`A | (B / C)`, B moving left), it
    ///    leaves that split and stands beside what remains (`A | (B | C)`).
    /// 2. Otherwise, with a neighbour in the row, it passes a single pane by
    ///    exchanging places with it, or joins a split across the direction as
    ///    its nearest pane's new neighbour (`(A / B) | C`, C moving left, gives
    ///    `(A / C / B)` when A is nearest).
    /// 3. At the row's end, if the row does not span the tree, it leaves the
    ///    row and goes beyond it; failing that, it takes the whole tree's edge.
    /// 4. Already spanning that edge, nothing happens.
    @discardableResult
    func move(leaf: NSView, direction: SplitMoveDirection, inContainer container: NSView) -> Bool {
        guard leaf !== root, leaf.superview is NSSplitView else { return false }
        let across = direction.orientation
        if let parent = leaf.superview as? NSSplitView, parent.isVertical != across.isVertical {
            // Rule 1: the outermost split across the direction, up to the row.
            var group: NSView = parent
            while let next = group.superview as? NSSplitView, next.isVertical != across.isVertical {
                group = next
            }
            wrap(group, afterRemoving: leaf, direction: direction)
            return true
        }
        var current = leaf
        var leftRow = false
        while current !== root, let parent = current.superview as? NSSplitView {
            let index = parent.subviews.firstIndex(of: current) ?? 0
            let neighbour = parent.subviews[index == 0 ? 1 : 0]
            if parent.isVertical != across.isVertical {
                leftRow = true
            } else if index == (direction.towardFirst ? 1 : 0) {
                if leftRow {
                    wrap(current, afterRemoving: leaf, direction: direction)
                } else {
                    enter(neighbour, leaf: leaf, direction: direction, inContainer: container)
                }
                return true
            }
            current = parent
        }
        guard leftRow else { return false }
        wrap(root, afterRemoving: leaf, direction: direction)
        return true
    }

    /// Rule 2: the first pane or cross split at `sibling`'s near end.
    private func enter(
        _ sibling: NSView, leaf: NSView, direction: SplitMoveDirection, inContainer container: NSView
    ) {
        var target = sibling
        while let split = target as? NSSplitView, split.isVertical == direction.orientation.isVertical {
            target = split.subviews[direction.towardFirst ? 1 : 0]
        }
        guard target is NSSplitView else {
            swap(leaf, target)
            return
        }
        let nearest = self.leaf(from: leaf, direction: direction, inContainer: container)
        let anchor = nearest.flatMap { $0.isDescendant(of: target) ? $0 : nil } ?? leaves(of: target)[0]
        let frame = anchor.frame
        close(leaf: leaf)
        let across: SplitOrientation = direction.orientation == .columns ? .rows : .columns
        split(leaf: anchor, orientation: across, newLeaf: leaf).frame = frame
    }

    /// `leaf` leaves its place and stands beside `group`, on the direction's
    /// side. A `group` the removal collapsed is whatever took its place.
    private func wrap(_ group: NSView, afterRemoving leaf: NSView, direction: SplitMoveDirection) {
        let frame = group.frame
        let collapses = leaf.superview === group
        let survivor = close(leaf: leaf)
        let target = collapses ? (survivor ?? root) : group
        let node = split(
            leaf: target, orientation: direction.orientation, newLeaf: leaf,
            newLeafFirst: direction.towardFirst)
        node.frame = frame
    }

    private func leaves(of view: NSView) -> [NSView] {
        guard let split = view as? NSSplitView else { return [view] }
        return split.subviews.flatMap { leaves(of: $0) }
    }
}

extension SplitMoveDirection {
    /// The split that puts two panes on this direction's axis.
    var orientation: SplitOrientation { self == .left || self == .right ? .columns : .rows }
    /// An NSSplitView's first child is its left or top one.
    var towardFirst: Bool { self == .left || self == .up }
}
