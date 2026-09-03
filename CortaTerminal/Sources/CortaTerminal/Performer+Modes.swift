extension Performer {
    /// DECSET / DECRST — `CSI ? Pm h` / `CSI ? Pm l`. Only the flags the app
    /// layer reads are tracked; every other mode is ignored cleanly
    /// (`SECURITY.md` §3).
    mutating func applyPrivateModes(_ parameters: Parameters, enabled: Bool) {
        var index = 0
        while index < parameters.count {
            switch parameters[index] {
            case 2004:  // bracketed paste (M2.6)
                state.bracketedPasteEnabled = enabled
            case 1006:  // SGR mouse reporting (M2.7)
                state.sgrMouseEncodingEnabled = enabled
            case 2026:  // synchronized output (M4.3)
                state.synchronizedOutputEnabled = enabled
            case 1004:  // focus reporting (M6.7)
                state.focusReportingEnabled = enabled
            default:
                break
            }
            index += 1
        }
    }

    /// SM / RM — `CSI Pm h` / `CSI Pm l`, the ANSI (non-private) modes.
    ///
    /// Two of the four modes a real program touches are implemented here for
    /// real; the other two are deliberately not, and DECRQM says so
    /// (`ansiModeSetting`) rather than tracking a bit nothing acts on:
    ///
    /// - **IRM (4)** — insert/replace. Implemented: `Grid.insertMode`.
    /// - **LNM (20)** — line feed / new line. Implemented:
    ///   `PerformerState.newLineModeEnabled`, honoured by `execute` for LF,
    ///   VT and FF and by the app for the Return key.
    /// - **KAM (2)** — keyboard action mode, which locks the keyboard. Not
    ///   implemented: the keyboard belongs to the app layer and to the
    ///   window server, a terminal that stops accepting input on a byte from
    ///   the child is a terminal a runaway program can wedge, and there is
    ///   no way for the user to tell a locked keyboard from a hung app.
    ///   DECRQM answers 4, permanently reset.
    /// - **SRM (12)** — send/receive, i.e. local echo. Not implemented: the
    ///   grid draws what the child sends and Corta never echoes keystrokes
    ///   itself, so there is no local echo to switch off. DECRQM answers 4.
    ///
    /// Every other ANSI mode is ignored cleanly (`SECURITY.md` §3).
    mutating func applyAnsiModes(_ parameters: Parameters, enabled: Bool) {
        var index = 0
        while index < parameters.count {
            switch parameters[index] {
            case 4:  // IRM
                grid.insertMode = enabled
            case 20:  // LNM
                state.newLineModeEnabled = enabled
            default:
                break
            }
            index += 1
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
