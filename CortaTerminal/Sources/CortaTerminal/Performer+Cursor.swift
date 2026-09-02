extension Performer {
    /// Cursor motion — ECMA-48 §8.3: CUU, CUD, CUF, CUB, CUP, HVP, and the
    /// absolute and relative position sequences CHA, HPA, HPR, VPA and VPR.
    ///
    /// The absolute ones are not decoration. A TUI that lays a line out in
    /// segments — Ink, and so Claude Code — writes a segment, jumps to the
    /// next column with `CSI n G`, and writes the next. Left unimplemented
    /// the jump did nothing, every segment landed against the one before it,
    /// and a whole screen rendered with its spacing collapsed.
    ///
    /// Returns false when `final` is not a cursor sequence, so the dispatch
    /// table in `Performer.swift` can fall through to the next category.
    mutating func performCursorControl(final: UInt8, parameters: Parameters) -> Bool {
        switch final {
        case 0x41:  // CUU
            grid.moveCursorUp(parameters.value(0, default: 1))
        case 0x42:  // CUD
            grid.moveCursorDown(parameters.value(0, default: 1))
        case 0x43:  // CUF
            grid.moveCursorRight(parameters.value(0, default: 1))
        case 0x44:  // CUB
            grid.moveCursorLeft(parameters.value(0, default: 1))
        case 0x48, 0x66:  // CUP, HVP — one-based on the wire, zero-based here
            grid.moveCursor(
                row: parameters.value(0, default: 1) - 1,
                column: parameters.value(1, default: 1) - 1
            )
        case 0x47, 0x60:  // CHA, HPA — absolute column, row unchanged
            grid.moveCursor(
                row: grid.cursor.row,
                column: parameters.value(0, default: 1) - 1
            )
        case 0x61:  // HPR — relative column, same effect as CUF
            grid.moveCursorRight(parameters.value(0, default: 1))
        case 0x64:  // VPA — absolute row, column unchanged
            grid.moveCursor(
                row: parameters.value(0, default: 1) - 1,
                column: grid.cursor.column
            )
        case 0x65:  // VPR — relative row, same effect as CUD
            grid.moveCursorDown(parameters.value(0, default: 1))
        default:
            return false
        }
        return true
    }
}
