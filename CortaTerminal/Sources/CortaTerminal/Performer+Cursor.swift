extension Performer {
    /// Cursor motion — ECMA-48 §8.3: CUU, CUD, CUF, CUB, CUP and HVP.
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
        default:
            return false
        }
        return true
    }
}
