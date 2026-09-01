extension Performer {
    // Editing sequences — IL, DL, ICH, DCH, SU, SD — plus DECSC/DECRC and
    // DECSCUSR land here in M2.5.
    //
    // This file also hosts the `?1049` alternate-screen mode (M2.3).
    // Performer+Modes.swift is the natural home for it but belongs to the
    // track implementing M2.6/M2.7; keeping it here avoids two tracks
    // editing one file. The integrator can move it wholesale.

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
        default: break
        }
    }

    /// DECSET/DECRST with the `?` private marker (xterm ctlseqs, "DEC
    /// Private Mode Set/Reset"). Returns false when none of the parameters
    /// is a mode this handler owns.
    ///
    /// Only the `?1049` alternate screen is implemented. `?47` and `?1047`
    /// are deliberately not: they keep the alternate screen's contents
    /// across switches, and this grid discards them on exit — a half-right
    /// `?1047` is worse than a clean ignore. Everything else is ignored
    /// cleanly (`SECURITY.md` §3).
    mutating func performAlternateScreenMode(final: UInt8, parameters: Parameters) -> Bool {
        let set: Bool
        switch final {
        case 0x68: set = true   // DECSET
        case 0x6C: set = false  // DECRST
        default: return false
        }
        var handled = false
        for index in 0..<parameters.count {
            // xterm ctlseqs, Ps = 1049: save cursor, use and clear the
            // alternate screen on set; restore both on reset.
            if parameters[index] == 1049 {
                if set { grid.enterAlternateScreen() } else { grid.exitAlternateScreen() }
                handled = true
            }
        }
        return handled
    }
}
