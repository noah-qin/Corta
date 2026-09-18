import AppKit
import CortaTerminal
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

extension MouseReportingTests {
    @Test func motionEncodesHeldAndUnheldButtons() {
        #expect(SGRMouse.motion(button: .left, column: 5, row: 3) == Array("\u{1B}[<32;6;4M".utf8))
        #expect(SGRMouse.motion(button: .right, column: 0, row: 0, modifiers: .init(control: true)) == Array("\u{1B}[<50;1;1M".utf8))
        #expect(SGRMouse.motion(button: nil, column: 5, row: 3) == Array("\u{1B}[<35;6;4M".utf8))
    }

    @MainActor private func mouseEvent(_ type: NSEvent.EventType, x: CGFloat = 15,
                                       flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 15), modifierFlags: flags,
                          timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
                          clickCount: 1, pressure: 1)!
    }

    @MainActor @Test func modesGateMotionAndCoalesceByCell() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.cellSize = CGSize(width: 10, height: 10)
        view.cellAtPoint = { (column: Int($0.x / 10), row: 1) }
        var mode = CortaTerminal.MouseTrackingMode.off
        view.mouseTrackingMode = { mode }
        var reports: [[UInt8]] = []
        view.onMouseBytes = { reports.append($0) }
        view.mouseMoved(with: mouseEvent(.mouseMoved))
        #expect(reports.isEmpty)
        mode = .normal
        view.mouseDown(with: mouseEvent(.leftMouseDown))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, x: 25))
        #expect(reports.count == 1)
        mode = .buttonEvent
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, x: 25))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, x: 26))
        #expect(reports.count == 2)
        #expect(reports.last == Array("\u{1B}[<32;3;2M".utf8))
        view.mouseUp(with: mouseEvent(.leftMouseUp, x: 25))
        view.mouseMoved(with: mouseEvent(.mouseMoved, x: 35))
        #expect(reports.count == 3)
        mode = .anyEvent
        view.mouseMoved(with: mouseEvent(.mouseMoved, x: 35))
        #expect(reports.last == Array("\u{1B}[<35;4;2M".utf8))
        #expect(reports.count == 4)
    }

    @MainActor @Test func overrideNeverLeaksADragOrReleaseAfterModifierChanges() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.cellSize = CGSize(width: 10, height: 10)
        view.mouseTrackingMode = { .anyEvent }
        var reports: [[UInt8]] = []
        view.onMouseBytes = { reports.append($0) }
        for modifier in Configuration.MouseOverrideModifier.allCases {
            view.mouseOverrideModifier = modifier
            view.mouseDown(with: mouseEvent(.leftMouseDown, flags: modifier.flags))
            view.mouseDragged(with: mouseEvent(.leftMouseDragged, x: 25))
            view.mouseUp(with: mouseEvent(.leftMouseUp, x: 25))
            view.mouseMoved(with: mouseEvent(.mouseMoved, x: 35, flags: modifier.flags))
        }
        #expect(reports.isEmpty)
    }
}
