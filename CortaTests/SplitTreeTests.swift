import AppKit
import Testing

@testable import Corta

/// M5.1 — the binary layout tree. Exercised with plain `NSView`s: the tree
/// surgery is view-hierarchy work and needs no session, no Metal and no
/// window.
@MainActor
struct SplitTreeTests {
    private func leaf() -> NSView { NSView(frame: .zero) }

    /// Every internal node holds exactly two children; `leaves` walks in
    /// tree order.
    @Test func splitReplacesLeafWithABinaryNode() {
        let a = leaf()
        let tree = SplitTree(root: a)
        let b = leaf()

        let node = tree.split(leaf: a, orientation: .columns, newLeaf: b)

        #expect(tree.root === node)
        #expect(node.isVertical)
        #expect(node.subviews == [a, b])
        #expect(tree.leaves == [a, b])
    }

    @Test func rowsOrientationIsAHorizontalSplitView() {
        let a = leaf()
        let tree = SplitTree(root: a)
        let node = tree.split(leaf: a, orientation: .rows, newLeaf: leaf())
        #expect(!node.isVertical)
    }

    /// Splitting a nested leaf grows the tree in place: the new node takes
    /// the leaf's slot in its parent, and the root is untouched.
    @Test func nestedSplitKeepsRootAndOrder() {
        let a = leaf()
        let tree = SplitTree(root: a)
        let b = leaf()
        let rootNode = tree.split(leaf: a, orientation: .columns, newLeaf: b)
        let c = leaf()

        let nested = tree.split(leaf: b, orientation: .rows, newLeaf: c)

        #expect(tree.root === rootNode)
        #expect(rootNode.subviews == [a, nested])
        #expect(nested.subviews == [b, c])
        #expect(tree.leaves == [a, b, c])
    }

    /// Closing one child of a two-child node collapses the node into the
    /// surviving sibling — the tree stays binary.
    @Test func closeCollapsesTheParentNode() {
        let a = leaf()
        let tree = SplitTree(root: a)
        let b = leaf()
        tree.split(leaf: a, orientation: .columns, newLeaf: b)

        let surviving = tree.close(leaf: b)

        #expect(surviving === a)
        #expect(tree.root === a)
        #expect(tree.leaves == [a])
    }

    @Test func nestedCloseLiftsTheSiblingIntoTheGrandparent() {
        let a = leaf()
        let tree = SplitTree(root: a)
        let b = leaf()
        let rootNode = tree.split(leaf: a, orientation: .columns, newLeaf: b)
        let c = leaf()
        tree.split(leaf: b, orientation: .rows, newLeaf: c)

        let surviving = tree.close(leaf: c)

        #expect(surviving === b)
        #expect(rootNode.subviews == [a, b])
        #expect(tree.leaves == [a, b])
    }

    @Test func closingTheRootLeafIsRefused() {
        let a = leaf()
        let tree = SplitTree(root: a)
        #expect(tree.close(leaf: a) == nil)
        #expect(tree.root === a)
    }

    /// Focus movement is geometric: the nearest leaf strictly past the
    /// current one along the direction's axis, lateral offset as tie-break.
    /// Frames are set by hand — the split views' own layout is AppKit's,
    /// not the tree's.
    @Test func focusMovementPicksTheNearestLeafInDirection() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let a = leaf()
        let tree = SplitTree(root: a)
        let b = leaf()
        let rootNode = tree.split(leaf: a, orientation: .columns, newLeaf: b)
        let c = leaf()
        let nested = tree.split(leaf: b, orientation: .rows, newLeaf: c)
        container.addSubview(rootNode)

        // A fills the left half; B sits over C on the right. AppKit's split
        // views are flipped (y=0 is the visual top), so in the nested
        // split's coordinates B gets the *smaller* y.
        rootNode.frame = container.bounds
        a.frame = NSRect(x: 0, y: 0, width: 200, height: 140)
        nested.frame = NSRect(x: 200, y: 0, width: 200, height: 400)
        b.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        c.frame = NSRect(x: 0, y: 200, width: 200, height: 200)

        #expect(tree.leaf(from: c, direction: .up, inContainer: container) === b)
        #expect(tree.leaf(from: b, direction: .down, inContainer: container) === c)
        // A's center sits in the upper half, so B is nearer than C.
        #expect(tree.leaf(from: a, direction: .right, inContainer: container) === b)
        #expect(tree.leaf(from: b, direction: .left, inContainer: container) === a)
        #expect(tree.leaf(from: a, direction: .left, inContainer: container) == nil)
        #expect(tree.leaf(from: a, direction: .up, inContainer: container) == nil)
    }

    /// A 2×2 split — columns, then each column split into rows, exactly the
    /// shape ⌘D then ⌘⇧D on each half produces — must tile the window
    /// completely once AppKit has laid the split views out: the four leaves
    /// share only the hairline dividers, with no gap and no overlap
    /// anywhere. A screenshot test alone (`SplitPaneUITests`) can show this
    /// to a person but asserts nothing; this is the geometric check behind
    /// it.
    @Test func twoByTwoSplitTilesTheContainerWithNoGapOrOverlap() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let topLeft = leaf()
        let tree = SplitTree(root: topLeft)
        let topRight = leaf()
        let columns = tree.split(leaf: topLeft, orientation: .columns, newLeaf: topRight)
        let bottomLeft = leaf()
        let leftColumn = tree.split(leaf: topLeft, orientation: .rows, newLeaf: bottomLeft)
        let bottomRight = leaf()
        let rightColumn = tree.split(leaf: topRight, orientation: .rows, newLeaf: bottomRight)

        columns.translatesAutoresizingMaskIntoConstraints = true
        columns.frame = container.bounds
        container.addSubview(columns)
        container.layoutSubtreeIfNeeded()
        // Explicit divider positions, exactly as `SplitViewController` sets
        // them after a split, rather than whatever default AppKit chose.
        columns.setPosition(container.bounds.width / 2, ofDividerAt: 0)
        leftColumn.setPosition(leftColumn.bounds.height / 2, ofDividerAt: 0)
        rightColumn.setPosition(rightColumn.bounds.height / 2, ofDividerAt: 0)
        container.layoutSubtreeIfNeeded()

        let leaves = [topLeft, topRight, bottomLeft, bottomRight]
        let frames = leaves.map { $0.convert($0.bounds, to: container) }

        // No two leaves claim the same pixel — the dividers sit in the gaps
        // between them, never inside a leaf's own frame.
        for i in 0..<frames.count {
            for j in (i + 1)..<frames.count {
                let overlap = frames[i].intersection(frames[j])
                #expect(overlap.isEmpty || overlap.width * overlap.height < 1)
            }
        }

        // Together the four reach every edge of the container — a leaf
        // stranded away from the frame it should touch is exactly the "top
        // border missing" shape this suite exists to catch.
        let union = frames.reduce(NSRect.null) { $0.union($1) }
        #expect(abs(union.minX - container.bounds.minX) < 1)
        #expect(abs(union.minY - container.bounds.minY) < 1)
        #expect(abs(union.maxX - container.bounds.maxX) < 1)
        #expect(abs(union.maxY - container.bounds.maxY) < 1)

        // Their combined area accounts for the whole container save for the
        // two hairline dividers — nothing else is unaccounted for.
        let totalLeafArea = frames.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        let containerArea = container.bounds.width * container.bounds.height
        let dividerAllowance =
            2 * 1 * max(container.bounds.width, container.bounds.height)
        #expect(containerArea - totalLeafArea <= dividerAllowance)
    }

    /// The window's minimum size is the tree's minimum: along a split's
    /// axis the children add (plus the divider), across it they max.
    @Test func minimumSizeCombinesAlongTheAxisAndMaxesAcrossIt() {
        let a = leaf()
        let tree = SplitTree(root: a)
        let b = leaf()
        let rootNode = tree.split(leaf: a, orientation: .columns, newLeaf: b)
        let c = leaf()
        tree.split(leaf: b, orientation: .rows, newLeaf: c)

        let sizes: [ObjectIdentifier: CGSize] = [
            ObjectIdentifier(a): CGSize(width: 100, height: 50),
            ObjectIdentifier(b): CGSize(width: 80, height: 30),
            ObjectIdentifier(c): CGSize(width: 60, height: 40),
        ]
        let size = tree.minimumSize(
            of: tree.root,
            leafSize: { sizes[ObjectIdentifier($0)] ?? .zero },
            dividerThickness: 1)

        // Right column: 80x30 stacked on 60x40 with a divider → 80x71.
        // Root: 100x50 beside 80x71 with a divider → 181x71.
        #expect(size == CGSize(width: 181, height: 71))
        #expect(rootNode.isVertical)
    }
}
