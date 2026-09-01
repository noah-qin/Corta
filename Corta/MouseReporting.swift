import CoreGraphics

/// Translates mouse events into SGR (?1006) reports — press, release and
/// wheel, as `ESC [ < Cb ; Cx ; Cy M` (press/wheel) or `... m` (release)
/// (ROADMAP.md M2.7).
///
/// `nonisolated`: pure byte encoding, no AppKit — the app target's MainActor
/// default would only make it untestable.
nonisolated enum SGRMouse {
    enum Button {
        case left, middle, right

        /// The SGR button code: 0 left, 1 middle, 2 right.
        var code: Int {
            switch self {
            case .left: return 0
            case .middle: return 1
            case .right: return 2
            }
        }
    }

    /// The modifier bits an SGR report carries: Shift 4, Meta/Option 8,
    /// Control 16.
    struct Modifiers {
        var shift = false
        var meta = false
        var control = false

        var bits: Int {
            (shift ? 4 : 0) | (meta ? 8 : 0) | (control ? 16 : 0)
        }
    }

    /// The 0-based cell under `point` (view coordinates, top-left origin, y
    /// down — `TerminalView` is flipped), clamped to the grid. Points outside
    /// the view report the edge cell, matching xterm.
    static func cell(for point: CGPoint, cellWidth: CGFloat, cellHeight: CGFloat) -> (
        column: Int, row: Int
    ) {
        let column = max(0, Int((point.x / cellWidth).rounded(.down)))
        let row = max(0, Int((point.y / cellHeight).rounded(.down)))
        return (column, row)
    }

    /// A button press at a 0-based cell.
    static func press(button: Button, column: Int, row: Int, modifiers: Modifiers = Modifiers())
        -> [UInt8]
    {
        report(code: button.code | modifiers.bits, column: column, row: row, final: 0x4D)  // 'M'
    }

    /// A button release. In SGR mode (unlike X10/normal) the release reports
    /// the actual released button, with a lowercase 'm' final.
    static func release(button: Button, column: Int, row: Int, modifiers: Modifiers = Modifiers())
        -> [UInt8]
    {
        report(code: button.code | modifiers.bits, column: column, row: row, final: 0x6D)  // 'm'
    }

    /// One wheel notch: 64 up, 65 down. Wheel events have no release report.
    static func wheel(up: Bool, column: Int, row: Int, modifiers: Modifiers = Modifiers()) -> [UInt8] {
        report(code: (up ? 64 : 65) | modifiers.bits, column: column, row: row, final: 0x4D)
    }

    /// `ESC [ < Cb ; Cx ; Cy <final>` — coordinates are 1-based on the wire.
    private static func report(code: Int, column: Int, row: Int, final: UInt8) -> [UInt8] {
        var bytes = Array("\u{1B}[<\(code);\(column + 1);\(row + 1)".utf8)
        bytes.append(final)
        return bytes
    }
}
