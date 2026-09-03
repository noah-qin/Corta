extension Performer {
    /// Editing sequences — IL, DL, ICH, DCH, SU, SD — plus DECSC/DECRC and
    /// DECSCUSR (M2.5).

    /// Editing and scroll-region sequences — ECMA-48 §8.3 and VT510.
    ///
    /// Returns false when `final` is not one of these, so the dispatch table
    /// in `Performer.swift` can fall through to the next category.
    mutating func performEditing(final: UInt8, parameters: Parameters) -> Bool {
        switch final {
        case 0x72:  // DECSTBM — VT510 §DECSTBM; one-based on the wire
            grid.setScrollRegion(
                top: parameters.value(0, default: 1) - 1,
                bottom: parameters.value(1, default: grid.rows) - 1
            )
        case 0x40:  // ICH — ECMA-48 §8.3.64
            grid.insertCharacters(parameters.value(0, default: 1))
        case 0x4C:  // IL — ECMA-48 §8.3.67
            grid.insertLines(parameters.value(0, default: 1))
        case 0x4D:  // DL — ECMA-48 §8.3.32
            grid.deleteLines(parameters.value(0, default: 1))
        case 0x50:  // DCH — ECMA-48 §8.3.26
            grid.deleteCharacters(parameters.value(0, default: 1))
        case 0x53:  // SU — ECMA-48 §8.3.147
            grid.scrollUp(parameters.value(0, default: 1))
        case 0x54:  // SD — ECMA-48 §8.3.113
            // More than one parameter is xterm's highlight-tracking
            // sequence sharing the final byte; that is not scrolling.
            if parameters.count <= 1 {
                grid.scrollDown(parameters.value(0, default: 1))
            }
        case 0x67:  // TBC — clear current (0/default) or all (3) tab stops
            let mode = parameters.value(0, default: 0)
            if mode == 0 { grid.clearTabStop(atCursorOnly: true) }
            if mode == 3 { grid.clearTabStop(atCursorOnly: false) }
        default:
            return false
        }
        return true
    }

    /// ESC sequences. Only DECSC/DECRC are implemented; charset selection
    /// and everything else are ignored cleanly (`SECURITY.md` §3).
    public mutating func escapeDispatch(intermediates: Intermediates, final: UInt8) {
        guard intermediates.count == 0 else { return }
        switch final {
        case 0x37: grid.saveCursor()     // DECSC — VT510 §DECSC
        case 0x38: grid.restoreCursor()  // DECRC — VT510 §DECRC
        case 0x44: grid.lineFeed()       // IND
        case 0x45:                       // NEL
            grid.carriageReturn()
            grid.lineFeed()
        case 0x48: grid.setTabStop()     // HTS
        case 0x4D: grid.reverseIndex()   // RI
        case 0x63: resetToInitialState() // RIS
        default: break
        }
    }

    private mutating func resetToInitialState() {
        // Dynamic colours originate in the active app theme, not in terminal
        // mode state; RIS resets modes, screens, title, tab stops and cursor
        // while keeping those resource values truthful for later queries.
        let colors = state.dynamicColors
        grid.resetToInitialState()
        state = PerformerState()
        state.dynamicColors = colors
    }

    /// CSI sequences carrying an intermediate byte. Only DECSCUSR is
    /// implemented; everything else is ignored cleanly.
    mutating func performIntermediate(
        final: UInt8,
        intermediates: Intermediates,
        parameters: Parameters
    ) -> Bool {
        // DECSTR — CSI ! p. This is a soft reset: content and the current
        // cursor survive, while margins, rendition and saved cursor reset.
        if intermediates.count == 1, intermediates[0] == 0x21, final == 0x70 {
            grid.softReset()
            return true
        }
        // DECSCUSR — xterm ctlseqs: `CSI Ps SP q` sets the cursor style.
        // The grid stores it; drawing it is the renderer's concern.
        guard intermediates.count == 1, intermediates[0] == 0x20, final == 0x71 else { return false }
        switch parameters[0] {
        case 0, 1: grid.cursorStyle = .blinkingBlock
        case 2: grid.cursorStyle = .block
        case 3: grid.cursorStyle = .blinkingUnderline
        case 4: grid.cursorStyle = .underline
        case 5: grid.cursorStyle = .blinkingBar
        case 6: grid.cursorStyle = .bar
        default: break
        }
        return true
    }
}
