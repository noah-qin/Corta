import CoreGraphics
import CoreText
import CortaTerminal
import Foundation
import Testing

@testable import Corta

/// U19, drag auto-scroll: the pure tick math behind the selection loop's
/// periodic-event branch. Inside the grid nothing scrolls; past the top or
/// bottom edge the viewport moves at a pace graded by overshoot, the head
/// keeps extending into the scrollback, and the clamped offset stops the
/// gesture at the scrollback's ends.
struct SelectionAutoScrollTests {
    private static let metrics = CellMetrics(
        font: CTFontCreateWithName("Menlo" as CFString, 14, nil))

    /// Same value as `SelectionCellMappingTests.topInset`: the grid's top
    /// edge in a window with a titlebar and no tab bar.
    private static let topInset = TerminalLayout.titlebarHeight + TerminalLayout.insets.top

    /// A view exactly as tall as the insets plus the grid, so the grid is
    /// top-anchored at `topInset` and its bottom edge is known exactly.
    private static func viewHeight(rows: Int) -> CGFloat {
        topInset + TerminalLayout.insets.bottom + CGFloat(rows) * metrics.cellHeight
    }

    /// A point `rows` cell heights below the grid's top edge; negative and
    /// beyond-`grid.rows` values land past the edges.
    private static func point(rows: Double, columns: Double = 2.5) -> CGPoint {
        CGPoint(
            x: TerminalLayout.insets.left + columns * metrics.cellWidth,
            y: topInset + rows * metrics.cellHeight)
    }

    private static func tick(
        at point: CGPoint, rows: Int = 30, scrollOffset: Int, historyDepth: Int = 100
    ) -> (scrollOffset: Int, head: SelectionPoint)? {
        ViewController.autoScrollTick(
            at: point, viewHeight: viewHeight(rows: rows), metrics: metrics,
            grid: Grid(rows: rows, columns: 120), scrollOffset: scrollOffset,
            historyDepth: historyDepth, topInset: topInset)
    }

    @Test func aPointerInsideTheGridDoesNotScroll() {
        #expect(Self.tick(at: Self.point(rows: 5), scrollOffset: 10)?.scrollOffset == nil)
        // Exactly on the edges is still inside.
        #expect(Self.tick(at: Self.point(rows: 0), scrollOffset: 10)?.scrollOffset == nil)
        #expect(Self.tick(at: Self.point(rows: 29.9), scrollOffset: 10)?.scrollOffset == nil)
    }

    @Test func aPointerJustPastTheTopScrollsUpOneRowPerTick() {
        let tick = Self.tick(at: Self.point(rows: -0.1), scrollOffset: 10)
        #expect(tick?.scrollOffset == 11)
    }

    @Test func thePaceGradesWithOvershootAndCaps() {
        // Five cell heights past the edge: 1 + 5/2 = 3 rows per tick.
        #expect(Self.tick(at: Self.point(rows: -5), scrollOffset: 10)?.scrollOffset == 13)
        // A pointer flung far past the window hits the 8-row cap.
        #expect(Self.tick(at: Self.point(rows: -100), scrollOffset: 10)?.scrollOffset == 18)
    }

    @Test func aPointerPastTheBottomScrollsBackDown() {
        let tick = Self.tick(at: Self.point(rows: 30.1), scrollOffset: 10)
        #expect(tick?.scrollOffset == 9)
        #expect(Self.tick(at: Self.point(rows: 35), scrollOffset: 10)?.scrollOffset == 7)
    }

    @Test func scrollingStopsAtTheScrollbackTop() {
        #expect(
            Self.tick(at: Self.point(rows: -1), scrollOffset: 100, historyDepth: 100)?
                .scrollOffset == nil,
            "at the top the offset cannot move and the tick does nothing")
        // A partial step still lands exactly on the boundary.
        #expect(
            Self.tick(at: Self.point(rows: -5), scrollOffset: 98, historyDepth: 100)?.scrollOffset
                == 100)
    }

    @Test func scrollingStopsAtTheLiveScreen() {
        #expect(
            Self.tick(at: Self.point(rows: 31), scrollOffset: 0)?.scrollOffset == nil,
            "offset zero is the live screen; scrolling further down is meaningless")
    }

    @Test func theHeadExtendsIntoTheScrollbackAsTheViewportScrolls() {
        // Pointer parked past the top edge: each tick clamps the viewport
        // row to 0 and subtracts the growing offset, so the document row
        // walks one line deeper into the scrollback per tick.
        var scrollOffset = 10
        for expectedRow in [-11, -12, -13] {
            let tick = Self.tick(at: Self.point(rows: -0.5), scrollOffset: scrollOffset)
            #expect(tick?.head.row == expectedRow)
            #expect(tick?.head.column == 2)
            if let tick { scrollOffset = tick.scrollOffset }
        }
        #expect(scrollOffset == 13)
    }

    @Test func theHeadFollowsTheBottomEdgeWhileScrollingDown() {
        // Mirrored on the live-screen side: the viewport row clamps to the
        // last row and the shrinking offset moves the head down the document.
        let tick = Self.tick(at: Self.point(rows: 31), scrollOffset: 10)
        #expect(tick?.scrollOffset == 9)
        #expect(tick?.head.row == 29 - 9)
    }
}
