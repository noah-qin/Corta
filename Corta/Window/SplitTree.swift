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

/// The split layout is a binary tree: a leaf is a pane's view, an
/// internal node is an `NSSplitView` with exactly two children. Splitting a
/// leaf replaces it with a node holding the old leaf and the new one;
/// closing a leaf collapses its parent node into the surviving sibling, so
/// every node keeps exactly two children by construction.
///
/// The tree is the view hierarchy itself — no parallel model to keep in
/// sync. This type owns the surgery; `SplitViewController` owns the panes
/// the leaves belong to. Everything here works on plain `NSView`s so the
/// tree is testable without spawning a session (`SplitTreeTests`).
///
/// Orientation follows `NSSplitView.isVertical`: `.columns` is a vertical
/// divider with panes side by side, `.rows` a horizontal divider with
/// panes stacked.
enum SplitOrientation {
    /// Vertical divider; the new pane appears to the right.
    case columns
    /// Horizontal divider; the new pane appears below.
    case rows

    var isVertical: Bool { self == .columns }
}

/// A direction for geometric focus movement (⌘⌥ arrows).
enum SplitMoveDirection {
    case left, right, up, down
}

@MainActor
final class SplitTree {
    /// The leaf view, or the root `NSSplitView`. The container swaps its
    /// only subview whenever this changes.
    private(set) var root: NSView

    init(root: NSView) {
        self.root = root
    }

    /// Every leaf, in tree order.
    var leaves: [NSView] {
        var result: [NSView] = []
        collectLeaves(of: root, into: &result)
        return result
    }

    var leafCount: Int { leaves.count }

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

    private func collectLeaves(of view: NSView, into leaves: inout [NSView]) {
        if let split = view as? NSSplitView {
            for child in split.subviews { collectLeaves(of: child, into: &leaves) }
        } else {
            leaves.append(view)
        }
    }

    /// Replaces `leaf` with a node splitting it against `newLeaf`. Returns
    /// the subtree that took the leaf's place — the new node itself — so
    /// the caller can position the divider. The caller swaps the container's
    /// subview when the root changed (`splitReturningSubtree == root`).
    @discardableResult
    func split(
        leaf: NSView, orientation: SplitOrientation, newLeaf: NSView, newLeafFirst: Bool = false
    ) -> NSSplitView {
        let node = makeSplitView(orientation: orientation)
        // Arranged subviews of an NSSplitView are frame-managed by the
        // split view itself — Auto Layout masks fight it. The container
        // re-enables constraints on the root when it installs one.
        node.translatesAutoresizingMaskIntoConstraints = true
        leaf.translatesAutoresizingMaskIntoConstraints = true
        newLeaf.translatesAutoresizingMaskIntoConstraints = true
        if leaf === root {
            root = node
        } else if let parent = leaf.superview as? NSSplitView,
            let index = parent.subviews.firstIndex(of: leaf)
        {
            leaf.removeFromSuperview()
            parent.insertArrangedSubview(node, at: index)
        }
        node.addArrangedSubview(newLeafFirst ? newLeaf : leaf)
        node.addArrangedSubview(newLeafFirst ? leaf : newLeaf)
        return node
    }

    /// Removes `leaf` and collapses its parent node into the surviving
    /// sibling subtree. Returns that subtree — the caller focuses a pane in
    /// it — or nil when `leaf` is the root and there is nothing to close
    /// (the caller closes the window instead).
    @discardableResult
    func close(leaf: NSView) -> NSView? {
        guard leaf !== root, let parent = leaf.superview as? NSSplitView else { return nil }
        guard let sibling = parent.subviews.first(where: { $0 !== leaf }) else { return nil }
        leaf.removeFromSuperview()
        sibling.translatesAutoresizingMaskIntoConstraints = true
        if parent === root {
            parent.removeFromSuperview()
            root = sibling
        } else if let grandparent = parent.superview as? NSSplitView,
            let index = grandparent.subviews.firstIndex(of: parent)
        {
            parent.removeFromSuperview()
            grandparent.insertArrangedSubview(sibling, at: index)
        }
        return sibling
    }

    /// `other` takes `leaf`'s place in this tree, and `leaf` is out of it.
    /// The container installs a new root.
    func replace(leaf: NSView, with other: NSView) {
        other.frame = leaf.frame
        other.translatesAutoresizingMaskIntoConstraints = true
        if leaf === root {
            root = other
        } else if let parent = leaf.superview as? NSSplitView {
            parent.replaceSubview(leaf, with: other)
        }
    }

    /// The nearest leaf in `direction`, measured in `container`'s
    /// coordinate space: a candidate must lie strictly past the current
    /// leaf's center along the axis, and the winner minimizes axial distance
    /// with a penalty for lateral offset. Returns nil when nothing lies
    /// that way.
    func leaf(
        from leaf: NSView, direction: SplitMoveDirection, inContainer container: NSView
    ) -> NSView? {
        let origin = center(of: leaf, in: container)
        var best: (view: NSView, score: CGFloat)?
        for candidate in leaves where candidate !== leaf {
            let center = center(of: candidate, in: container)
            let dx = center.x - origin.x
            let dy = center.y - origin.y
            let axial: CGFloat
            let lateral: CGFloat
            // The tree's views are ordinary unflipped NSViews: +y is up.
            switch direction {
            case .left: axial = -dx; lateral = abs(dy)
            case .right: axial = dx; lateral = abs(dy)
            case .up: axial = dy; lateral = abs(dx)
            case .down: axial = -dy; lateral = abs(dx)
            }
            guard axial > 0.5 else { continue }
            let score = axial + lateral * 2
            if best == nil || score < best!.score {
                best = (candidate, score)
            }
        }
        return best?.view
    }

    private func center(of view: NSView, in container: NSView) -> CGPoint {
        let frame = view.convert(view.bounds, to: container)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// The smallest size a subtree can take: a leaf reports its own
    /// minimum; a node adds the divider and combines its children along its
    /// axis, taking the larger across it. Used for the window's minimum
    /// size and for clamping divider drags.
    func minimumSize(
        of subtree: NSView, leafSize: (NSView) -> CGSize, dividerThickness: CGFloat
    ) -> CGSize {
        guard let split = subtree as? NSSplitView, split.subviews.count == 2 else {
            return leafSize(subtree)
        }
        let first = minimumSize(of: split.subviews[0], leafSize: leafSize, dividerThickness: dividerThickness)
        let second = minimumSize(of: split.subviews[1], leafSize: leafSize, dividerThickness: dividerThickness)
        if split.isVertical {
            return CGSize(
                width: first.width + dividerThickness + second.width,
                height: max(first.height, second.height))
        }
        return CGSize(
            width: max(first.width, second.width),
            height: first.height + dividerThickness + second.height)
    }

    private func makeSplitView(orientation: SplitOrientation) -> NSSplitView {
        let split = PaneSplitView()
        split.isVertical = orientation.isVertical
        // A hairline divider; the panes' own backgrounds butt against it.
        split.dividerStyle = .thin
        return split
    }
}

/// The splitter is the gutter between independent rounded terminal cards.
final class PaneSplitView: NSSplitView {
    var onDividerInteraction: (() -> Void)?
    /// The user placed this divider, by dragging or from the keyboard;
    /// `auto-balance-panes` leaves it where it is. Equalize Panes clears it.
    var isUserPositioned = false
    override var dividerThickness: CGFloat { PaneSurfaceView.gap }

    override func mouseDown(with event: NSEvent) {
        onDividerInteraction?()
        let before = firstExtent
        // A divider drag tracks inside this call and returns when it ends.
        super.mouseDown(with: event)
        if firstExtent != before { isUserPositioned = true }
    }

    private var firstExtent: CGFloat {
        guard let first = subviews.first else { return 0 }
        return isVertical ? first.frame.width : first.frame.height
    }

    override func drawDivider(in rect: NSRect) {
        PaneSurfaceView.gutterColor.setFill()
        rect.fill()
    }
}
