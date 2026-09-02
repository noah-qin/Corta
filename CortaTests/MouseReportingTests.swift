import CoreGraphics
import Foundation
import Testing

@testable import Corta

/// M2.7, app side: SGR (?1006) mouse reports are exact byte sequences —
/// `ESC [ < Cb ; Cx ; Cy M` for press and wheel, `... m` for release — with
/// 1-based coordinates derived from the cell metrics.
struct MouseReportingTests {
    @Test func leftClickAtKnownCellProducesExactSGRBytes() {
        // 0-based cell (5, 3) reports 1-based (6, 4); button code 0 = left.
        #expect(SGRMouse.press(button: .left, column: 5, row: 3) == Array("\u{1B}[<0;6;4M".utf8))
    }

    @Test func releaseReportsTheReleasedButtonWithLowercaseFinal() {
        #expect(SGRMouse.release(button: .left, column: 5, row: 3) == Array("\u{1B}[<0;6;4m".utf8))
        #expect(SGRMouse.release(button: .right, column: 0, row: 0) == Array("\u{1B}[<2;1;1m".utf8))
        #expect(SGRMouse.press(button: .middle, column: 0, row: 0) == Array("\u{1B}[<1;1;1M".utf8))
    }

    @Test func wheelUpAndDownAreButtons64And65() {
        #expect(SGRMouse.wheel(up: true, column: 0, row: 0) == Array("\u{1B}[<64;1;1M".utf8))
        #expect(SGRMouse.wheel(up: false, column: 9, row: 23) == Array("\u{1B}[<65;10;24M".utf8))
    }

    @Test func modifiersAddTheirBitsToTheButtonCode() {
        let ctrl = SGRMouse.Modifiers(control: true)
        #expect(SGRMouse.press(button: .left, column: 5, row: 3, modifiers: ctrl) == Array("\u{1B}[<16;6;4M".utf8))
        let shiftMeta = SGRMouse.Modifiers(shift: true, meta: true)
        #expect(SGRMouse.press(button: .right, column: 0, row: 0, modifiers: shiftMeta) == Array("\u{1B}[<14;1;1M".utf8))
        #expect(SGRMouse.wheel(up: true, column: 0, row: 0, modifiers: ctrl) == Array("\u{1B}[<80;1;1M".utf8))
    }

    @Test func cellCoordinatesComeFromTheMetrics() {
        // Menlo-14-like metrics; the point lands inside cell (5, 3).
        let (column, row) = SGRMouse.cell(
            for: CGPoint(x: 8.4 * 5 + 1, y: 17.0 * 3 + 1), cellWidth: 8.4, cellHeight: 17.0)
        #expect(column == 5)
        #expect(row == 3)
    }

    @Test func pointsOutsideTheViewClampToTheEdgeCell() {
        let (column, row) = SGRMouse.cell(
            for: CGPoint(x: -3, y: -12), cellWidth: 8.4, cellHeight: 17.0)
        #expect(column == 0)
        #expect(row == 0)
    }

    // View-creating tests are @MainActor: Swift Testing runs cases on
    // arbitrary threads, and AppKit view construction is main-thread only.

    @MainActor @Test func aShellProvidedMappingWinsOverTheRawDivide() {
        // The shell's mapping is inset-aware and bottom-anchored; the view
        // defers to it rather than dividing the raw point.
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        view.cellSize = CGSize(width: 9, height: 17)
        view.cellAtPoint = { _ in (column: 7, row: 4) }
        #expect(view.cellUnder(point: CGPoint(x: 1, y: 1)) == (column: 7, row: 4))
    }

    @MainActor @Test func withoutAShellMappingTheRawDivideApplies() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        view.cellSize = CGSize(width: 10, height: 20)
        #expect(view.cellUnder(point: CGPoint(x: 55, y: 45)) == (column: 5, row: 2))
    }
}
