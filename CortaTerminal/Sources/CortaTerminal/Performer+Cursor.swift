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
        case 0x45:  // CNL
            grid.moveToNextLine(parameters.value(0, default: 1))
        case 0x46:  // CPL
            grid.moveToPreviousLine(parameters.value(0, default: 1))
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
        case 0x49:  // CHT — forward horizontal tabulation
            grid.tabForward(parameters.value(0, default: 1))
        case 0x5A:  // CBT — backward horizontal tabulation
            grid.tabBackward(parameters.value(0, default: 1))
        // SCOSC / SCORC (ANSI.SYS; B06) — bare `CSI s` / `CSI u`, no private
        // marker, no intermediate, and — checked here — no parameters.
        // xterm treats the unmarked, unparameterized form as an alias for
        // DECSC/DECRC (`ESC 7`/`ESC 8`) unless DECLRMM (left/right margin
        // mode) is set — Corta has no margin mode to disambiguate against,
        // so the alias is unconditional, matching xterm's fallback
        // behaviour. `CSI ? u`/`CSI > u`/`CSI < u`/`CSI = u` (a private
        // marker) are the kitty keyboard protocol's query/push/pop forms
        // and are handled in `csiDispatch`'s marker branch before reaching
        // here, but the protocol's key-report form — `CSI code;modifiers u`,
        // unmarked but parameterized — reaches this switch on `final`
        // alone. Requiring zero parameters keeps a received key report
        // (e.g. `CSI 97;5u`) from being misread as a cursor restore.
        case 0x73 where parameters.count == 0:  // SCOSC
            grid.saveCursor()
        case 0x75 where parameters.count == 0:  // SCORC
            grid.restoreCursor()
        default:
            return false
        }
        return true
    }
}
