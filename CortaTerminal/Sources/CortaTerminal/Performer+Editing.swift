extension Performer {
    // Editing sequences — IL, DL, ICH, DCH, SU, SD — plus DECSC/DECRC and
    // DECSCUSR land here in M2.5.
    //
    // This file also hosts the `?1049` alternate-screen mode (M2.3).
    // Performer+Modes.swift is the natural home for it but belongs to the
    // track implementing M2.6/M2.7; keeping it here avoids two tracks
    // editing one file. The integrator can move it wholesale.

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
