/// M6.5 and M6.6 — the query class that used to time out.
///
/// The 184 esctest failures carried since M2 are dominated by probes that
/// wait for an answer Corta never sent: DECRQM asking whether a mode is on,
/// XTVERSION asking who the terminal is, and the query forms of OSC 10/11/12
/// asking what the default colours are. A probe that times out is not a
/// harmless omission — tmux and Neovim fall back to their most conservative
/// behaviour when a capability check goes unanswered (`CONFORMANCE.md` §1.2).
///
/// Every response here is a constant or numeric state formatted by this file.
/// Nothing from the input stream is ever echoed back, which is the rule that
/// keeps a query from becoming a command-injection vector
/// (`SECURITY.md` §2.1–§2.2).
extension Performer {
    /// XTVERSION — `CSI > Ps q`, answered `DCS > | text ST`.
    ///
    /// The name is a compile-time constant, so the answer cannot carry
    /// stream-supplied bytes. The version itself comes from `CortaVersion`,
    /// which is the single place it is written — it used to be spelled out
    /// here, where a release bump had no reason to look, and the answer went
    /// stale the moment `MARKETING_VERSION` moved.
    private static let versionReport = Array(
        "\u{1B}P>|\(CortaVersion.report)\u{1B}\\".utf8)

    mutating func reportVersion(_ parameters: Parameters) {
        // `CSI > 0 q` and `CSI > q` are the same request; any other Ps is a
        // different sequence and is not ours to answer.
        guard parameters.value(0, default: 0) == 0 else { return }
        state.outputBuffer.append(contentsOf: Self.versionReport)
    }

    /// DECRQM — `CSI Ps $ p` (ANSI modes) and `CSI ? Ps $ p` (DEC private
    /// modes), answered `CSI Ps ; Pm $ y` and `CSI ? Ps ; Pm $ y`.
    ///
    /// `Pm` is DEC's four-state answer: 0 not recognised, 1 set, 2 reset,
    /// 3 permanently set, 4 permanently reset. Answering 0 for a mode Corta
    /// does not implement is the honest reply and is what stops the probe
    /// blocking — silence is the only answer that hurts.
    mutating func reportMode(_ parameters: Parameters, isPrivate: Bool) {
        // DECRQM is a VT300-and-later sequence. A program that announced a
        // lower conformance level with DECSCL has asked to be talked to as
        // an older terminal, and answering anyway is the terminal ignoring
        // what it was told.
        guard state.conformanceLevel >= 63 else { return }
        let mode = parameters.value(0, default: 0)
        let marker = isPrivate ? "?" : ""
        let setting = isPrivate ? privateModeSetting(mode) : ansiModeSetting(mode)
        state.outputBuffer.append(
            contentsOf: Array("\u{1B}[\(marker)\(mode);\(setting)$y".utf8))
    }

    /// The DECRQM answer for a DEC private mode. Only modes whose state
    /// Corta actually knows report 1 or 2; everything else is 0, because
    /// claiming a mode is "reset" implies it could be set.
    private func privateModeSetting(_ mode: Int) -> Int {
        switch mode {
        case 1049: return grid.isAlternateScreenActive ? 1 : 2
        case 2004: return state.bracketedPasteEnabled ? 1 : 2
        case 1006: return state.sgrMouseEncodingEnabled ? 1 : 2
        case 2026: return state.synchronizedOutputEnabled ? 1 : 2
        case 1004: return state.focusReportingEnabled ? 1 : 2
        // `?7` (autowrap) and `?25` (cursor visibility) are permanently on:
        // the grid always wraps at the right margin and always has a cursor
        // the app may choose to draw. 3 says so — "set, and cannot be
        // reset" — rather than pretending they are toggles.
        case 7, 25: return 3
        default: return 0
        }
    }

    /// The DECRQM answer for an ANSI mode.
    ///
    /// The ECMA-48 modes below are *permanently reset* (4), not unknown:
    /// they describe hardware a terminal emulator has no analogue of —
    /// guarded areas, form feeds to a printer, transfer termination — and
    /// Corta will never implement them. 4 says exactly that, and is what
    /// xterm answers. It is a stronger and more useful answer than 0: a
    /// program learns not to ask again.
    ///
    /// Of the four ANSI modes a real program touches, two are implemented
    /// and report their live state, and two never will be and report 4:
    ///
    /// - IRM (4) and LNM (20) are implemented (`applyAnsiModes`), so 1 or 2
    ///   here is a fact about behaviour the terminal actually has.
    /// - KAM (2) locks the keyboard and SRM (12) turns on local echo. Corta
    ///   implements neither, on purpose — see `applyAnsiModes` for why — and
    ///   4 is the honest answer: not "unknown", but "reset, and it will stay
    ///   reset". A program learns not to ask again, which 0 does not tell it.
    ///
    /// Nothing here reports a bit Corta tracks but does not act on. That
    /// would be a lie a program can lay out a screen against, which is worse
    /// than admitting a mode is unimplemented.
    private func ansiModeSetting(_ mode: Int) -> Int {
        switch mode {
        case 4: return grid.insertMode ? 1 : 2
        case 20: return state.newLineModeEnabled ? 1 : 2
        // KAM and SRM: permanently reset, deliberately.
        case 2, 12: return 4
        // GATM, SRTM, VEM, HEM, PUM, FEAM, FETM, MATM, TTM, SATM, TSM, EBM.
        case 1, 5, 7, 10, 11, 13, 14, 15, 16, 17, 18, 19: return 4
        default: return 0
        }
    }

    /// The query form of OSC 10/11/12 — `OSC Ps ; ? ST`, answered
    /// `OSC Ps ; rgb:RRRR/GGGG/BBBB ST` (M6.6).
    ///
    /// xterm reports 16 bits per channel. Corta stores 8, so each byte is
    /// doubled — `0x23` becomes `2323` — which is exactly how xterm widens
    /// an 8-bit source too.
    mutating func reportDynamicColor(_ code: Int) {
        let color: (red: UInt8, green: UInt8, blue: UInt8)
        switch code {
        case 10: color = state.dynamicColors.foreground
        case 11: color = state.dynamicColors.background
        case 12: color = state.dynamicColors.cursor
        default: return
        }
        func channel(_ value: UInt8) -> String {
            let hex = String(value, radix: 16)
            let byte = hex.count == 1 ? "0" + hex : hex
            return byte + byte
        }
        let body = "rgb:\(channel(color.red))/\(channel(color.green))/\(channel(color.blue))"
        state.outputBuffer.append(contentsOf: Array("\u{1B}]\(code);\(body)\u{1B}\\".utf8))
    }

    /// The set form of OSC 10/11/12 — `OSC Ps ; spec ST`.
    ///
    /// Only the two specifications xterm defines are parsed: `#RRGGBB` and
    /// `rgb:R/G/B` with 1–4 hex digits per channel, scaled down to 8 bits.
    /// Anything else leaves the colour alone; a malformed spec must not
    /// half-apply.
    mutating func setDynamicColor(_ code: Int, specification: ArraySlice<UInt8>) {
        guard let color = Self.parseColorSpecification(specification) else { return }
        switch code {
        case 10: state.dynamicColors.foreground = color
        case 11: state.dynamicColors.background = color
        case 12: state.dynamicColors.cursor = color
        default: break
        }
    }

    /// The X11 colour specifications Corta accepts, and the ones it
    /// deliberately refuses.
    ///
    /// **Accepted.** `#RGB` through `#RRRRGGGGBBBB`, and `rgb:R/G/B` with one
    /// to four hex digits per channel. Between them these are what every
    /// program that sets a colour actually sends.
    ///
    /// **Refused, on purpose.** X11 also defines `rgbi:` (floating-point
    /// intensities) and four device-independent spaces — `CIELab:`,
    /// `CIEuvY:`, `CIExyY:`, `CIEXYZ:` and `TekHVC:`. Corta returns nil for
    /// all of them and leaves the colour unchanged, which the caller treats
    /// as "the sequence did nothing" (`setDynamicColor`).
    ///
    /// That is a decision, not an omission. Each of those is a colour-space
    /// conversion, not a parse: `CIELab` needs a white point and a gamma
    /// curve, and the answer depends on the display's profile — so an
    /// implementation is either colour-managed properly or it is a wrong
    /// number dressed as a right one. The esctest cases covering them are
    /// recorded as expected failures for exactly this reason
    /// (`docs/ROADMAP.md`, `docs/CONFORMANCE.md` §3). Refusing is also the
    /// safe direction: a program that sets a background it cannot verify and
    /// gets no change is a program whose text stays legible, whereas a
    /// mis-converted `CIELab` black-on-black is a terminal you cannot read.
    ///
    /// `rgbi:` is refused with the same reasoning and less regret — it is a
    /// second syntax for something `rgb:` already expresses exactly, and no
    /// program has been observed to send it.
    static func parseColorSpecification(_ bytes: ArraySlice<UInt8>)
        -> (red: UInt8, green: UInt8, blue: UInt8)?
    {
        let text = String(decoding: bytes, as: UTF8.self)
        if text.hasPrefix("#") {
            let digits = Array(text.dropFirst())
            // #RGB, #RRGGBB, #RRRGGGBBB and #RRRRGGGGBBBB are all legal;
            // every one divides evenly into three channels.
            guard digits.count % 3 == 0, !digits.isEmpty else { return nil }
            let width = digits.count / 3
            guard width <= 4 else { return nil }
            var channels: [UInt8] = []
            for index in 0..<3 {
                let slice = digits[(index * width)..<((index + 1) * width)]
                guard let value = UInt32(String(slice), radix: 16) else { return nil }
                channels.append(Self.scaleToByte(value, hexDigits: width))
            }
            return (channels[0], channels[1], channels[2])
        }
        // `rgb:` and nothing else. `rgbi:` shares the prefix, so the colon
        // has to be matched exactly or an intensity triple would be read as
        // hex and produce a colour nobody asked for.
        guard text.hasPrefix("rgb:") else { return nil }
        let parts = text.dropFirst(4).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var channels: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 4,
                let value = UInt32(String(part), radix: 16)
            else { return nil }
            channels.append(Self.scaleToByte(value, hexDigits: part.count))
        }
        return (channels[0], channels[1], channels[2])
    }

    /// Scales an n-hex-digit channel down to 8 bits the way xterm does:
    /// by the ratio of the two full-scale values, so `f` and `ffff` both
    /// become 255.
    private static func scaleToByte(_ value: UInt32, hexDigits: Int) -> UInt8 {
        let maximum = (UInt32(1) << (4 * UInt32(hexDigits))) - 1
        guard maximum > 0 else { return 0 }
        return UInt8((value * 255 + maximum / 2) / maximum)
    }

    // MARK: - Kitty keyboard protocol (M6.9)

    /// `CSI ? u` — report the flags in force, as `CSI ? flags u`.
    ///
    /// Reporting only the flags Corta honours is the point: a program that
    /// asks for event reporting and is told it got it would encode key
    /// releases nobody sends.
    mutating func reportKeyboardProtocol() {
        let flags = state.keyboardProtocol.current.rawValue
        state.outputBuffer.append(contentsOf: Array("\u{1B}[?\(flags)u".utf8))
    }

    /// `CSI > flags u` — push a new level onto the mode stack.
    mutating func pushKeyboardProtocol(_ parameters: Parameters) {
        state.keyboardProtocol.push(
            KeyboardEnhancementFlags(rawValue: UInt8(min(255, parameters.value(0, default: 0)))))
    }

    /// `CSI < number u` — pop `number` levels, default one.
    mutating func popKeyboardProtocol(_ parameters: Parameters) {
        state.keyboardProtocol.pop(parameters.value(0, default: 1))
    }

    /// `CSI = flags ; mode u` — set, add or remove flags at the current
    /// level.
    mutating func setKeyboardProtocol(_ parameters: Parameters) {
        state.keyboardProtocol.set(
            KeyboardEnhancementFlags(rawValue: UInt8(min(255, parameters.value(0, default: 0)))),
            mode: parameters.value(1, default: 1))
    }

    /// DECSCL — `CSI Ps ; Ps " p`. Sets the conformance level the terminal
    /// answers at; see `PerformerState.conformanceLevel`.
    ///
    /// The second parameter (7-bit versus 8-bit controls) is ignored: Corta
    /// emits 7-bit control sequences unconditionally, which is legal at
    /// every level and is what every modern terminal does.
    mutating func setConformanceLevel(_ parameters: Parameters) {
        let level = parameters.value(0, default: 65)
        guard (61...65).contains(level) else { return }
        state.conformanceLevel = level
    }
}
