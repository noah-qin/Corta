import AppKit

/// M5.1 — the split layout is a binary tree: a leaf is a pane's view, an
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

    fileprivate var isVertical: Bool { self == .columns }
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
    func split(leaf: NSView, orientation: SplitOrientation, newLeaf: NSView) -> NSSplitView {
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
        node.addArrangedSubview(leaf)
        node.addArrangedSubview(newLeaf)
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
    /// size and for clamping divider drags (M5.4).
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

/// The tree's internal node. The only reason to subclass is the divider:
/// the stock `.thin` divider draws in a system chrome colour that reads as
/// a harsh bright seam against the terminal's dark surface — and any
/// *translucent* fill shows straight through the window (the window's
/// background is `.clear`, so the 1pt strip between two opaque Metal
/// surfaces is a see-through slit). The divider is therefore the pane
/// background, painted opaque, with a barely-there light lift on top.
final class PaneSplitView: NSSplitView {
    override func drawDivider(in rect: NSRect) {
        let bg = TerminalColorPalette.defaultBackground
        NSColor(
            srgbRed: CGFloat(bg.x), green: CGFloat(bg.y), blue: CGFloat(bg.z), alpha: 1
        ).setFill()
        rect.fill()
        NSColor.white.withAlphaComponent(0.12).setFill()
        rect.fill()
    }
}
