// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

/// Probes a program waits on — DECRQM, XTVERSION, OSC 10/11/12 queries. An
/// unanswered probe drops tmux and Neovim to their most conservative
/// behaviour (`CONFORMANCE.md` §1.2). Every answer is a constant or numeric
/// state; nothing from the stream is echoed (`SECURITY.md` §2.1–§2.2).
extension Performer {
    /// XTVERSION: a compile-time constant, from `CortaVersion`.
    private static let versionReport = Array(
        "\u{1B}P>|\(CortaVersion.report)\u{1B}\\".utf8)

    mutating func reportVersion(_ parameters: Parameters) {
        guard parameters.value(0, default: 0) == 0 else { return }
        state.outputBuffer.append(contentsOf: Self.versionReport)
    }

    /// DECRQM. `Pm`: 0 unknown, 1 set, 2 reset, 3 permanently set, 4
    /// permanently reset. 0 for an unimplemented mode is honest; silence is the
    /// only answer that hurts.
    mutating func reportMode(_ parameters: Parameters, isPrivate: Bool) {
        // VT300+: a program that set a lower level with DECSCL asked not to hear it.
        guard state.conformanceLevel >= 63 else { return }
        let mode = parameters.value(0, default: 0)
        let marker = isPrivate ? "?" : ""
        let setting = isPrivate ? privateModeSetting(mode) : ansiModeSetting(mode)
        state.outputBuffer.append(
            contentsOf: Array("\u{1B}[\(marker)\(mode);\(setting)$y".utf8))
    }

    /// Only modes Corta actually tracks answer 1 or 2: "reset" implies it could
    /// be set.
    private func privateModeSetting(_ mode: Int) -> Int {
        switch mode {
        case 1: return state.applicationCursorKeysEnabled ? 1 : 2
        case 1049: return grid.isAlternateScreenActive ? 1 : 2
        case 2004: return state.bracketedPasteEnabled ? 1 : 2
        case 1000, 1002, 1003: return state.mouseTrackingMode.rawValue == mode ? 1 : 2
        case 1006: return state.sgrMouseEncodingEnabled ? 1 : 2
        case 2026: return state.synchronizedOutputEnabled ? 1 : 2
        case 1004: return state.focusReportingEnabled ? 1 : 2
        case 1007: return state.alternateScrollEnabled ? 1 : 2
        case 45: return grid.reverseWraparoundEnabled ? 1 : 2
        // Autowrap and a cursor are always present: permanently set.
        case 7, 25: return 3
        default: return 0
        }
    }

    /// IRM and LNM are implemented and report live state. KAM, SRM and the
    /// hardware-only ECMA-48 modes answer 4 (permanently reset), as xterm does —
    /// more useful than 0, since a program learns not to ask again. Nothing
    /// reports a bit Corta tracks but does not act on.
    private func ansiModeSetting(_ mode: Int) -> Int {
        switch mode {
        case 4: return grid.insertMode ? 1 : 2
        case 20: return state.newLineModeEnabled ? 1 : 2
        case 2, 12: return 4
        // GATM, SRTM, VEM, HEM, PUM, FEAM, FETM, MATM, TTM, SATM, TSM, EBM.
        case 1, 5, 7, 10, 11, 13, 14, 15, 16, 17, 18, 19: return 4
        default: return 0
        }
    }

    /// OSC 10/11/12 query: each 8-bit byte doubled to 16 bits, as xterm widens.
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

    /// OSC 10/11/12 set; a malformed spec leaves the colour alone.
    mutating func setDynamicColor(_ code: Int, specification: ArraySlice<UInt8>) {
        guard let color = Self.parseColorSpecification(specification) else { return }
        switch code {
        case 10: state.dynamicColors.foreground = color
        case 11: state.dynamicColors.background = color
        case 12: state.dynamicColors.cursor = color
        default: break
        }
    }

    /// Accepts `#RGB`…`#RRRRGGGGBBBB` and `rgb:R/G/B` (1–4 hex digits) — what
    /// programs send. Refuses `rgbi:` and the device-independent spaces
    /// (`CIELab:` …): each is a colour-managed conversion, and a wrong one is
    /// unreadable black-on-black where refusing leaves text legible. esctest's
    /// cases for them are expected failures (`CONFORMANCE.md` §3).
    static func parseColorSpecification(_ bytes: ArraySlice<UInt8>)
        -> (red: UInt8, green: UInt8, blue: UInt8)?
    {
        let text = String(decoding: bytes, as: UTF8.self)
        if text.hasPrefix("#") {
            let digits = Array(text.dropFirst())
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
        // Match the colon: `rgbi:` shares the prefix.
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

    // MARK: - OSC 4 / 104 — the indexed palette

    /// OSC 4: each `c ; spec` pair independent — `?` queries (16-bit, like
    /// OSC 10/11/12), anything else sets. A malformed pair is skipped, not the
    /// rest of the sequence, as xterm does.
    mutating func handleIndexedColor(_ payload: ArraySlice<UInt8>) {
        var start = payload.startIndex
        while start < payload.endIndex {
            // No `;` left: nothing more to apply.
            guard let firstSeparator = payload[start...].firstIndex(of: 0x3B) else { return }
            let specStart = payload.index(after: firstSeparator)
            let specEnd = payload[specStart...].firstIndex(of: 0x3B) ?? payload.endIndex
            defer {
                start = specEnd < payload.endIndex ? payload.index(after: specEnd) : payload.endIndex
            }
            guard let index = Self.parseByte(payload[start..<firstSeparator]) else { continue }
            let spec = payload[specStart..<specEnd]
            if spec.count == 1, spec.first == 0x3F {
                reportIndexedColor(index)
            } else if let color = Self.parseColorSpecification(spec) {
                state.indexedPalette.setOverride(index, to: color)
            }
        }
    }

    /// OSC 104: all overrides, or the named indices. Never answers.
    mutating func resetIndexedColors(_ payload: ArraySlice<UInt8>) {
        guard !payload.isEmpty else {
            state.indexedPalette.resetAllOverrides()
            return
        }
        var start = payload.startIndex
        while start < payload.endIndex {
            let end = payload[start...].firstIndex(of: 0x3B) ?? payload.endIndex
            if let index = Self.parseByte(payload[start..<end]) {
                state.indexedPalette.resetOverride(index)
            }
            start = end < payload.endIndex ? payload.index(after: end) : payload.endIndex
        }
    }

    private mutating func reportIndexedColor(_ index: UInt8) {
        let color = state.indexedPalette.color(at: index)
        func channel(_ value: UInt8) -> String {
            let hex = String(value, radix: 16)
            let byte = hex.count == 1 ? "0" + hex : hex
            return byte + byte
        }
        let body = "rgb:\(channel(color.red))/\(channel(color.green))/\(channel(color.blue))"
        state.outputBuffer.append(contentsOf: Array("\u{1B}]4;\(index);\(body)\u{1B}\\".utf8))
    }

    // MARK: - OSC 5 / 105 — the special colours

    /// OSC 5: OSC 4's shape over five slots. An unset slot queries as black —
    /// a query always gets a numeric answer.
    mutating func handleSpecialColor(_ payload: ArraySlice<UInt8>) {
        var start = payload.startIndex
        while start < payload.endIndex {
            guard let firstSeparator = payload[start...].firstIndex(of: 0x3B) else { return }
            let specStart = payload.index(after: firstSeparator)
            let specEnd = payload[specStart...].firstIndex(of: 0x3B) ?? payload.endIndex
            defer {
                start = specEnd < payload.endIndex ? payload.index(after: specEnd) : payload.endIndex
            }
            guard let slot = Self.parseSpecialColorSlot(payload[start..<firstSeparator]) else {
                continue
            }
            let spec = payload[specStart..<specEnd]
            if spec.count == 1, spec.first == 0x3F {
                reportSpecialColor(slot)
            } else if let color = Self.parseColorSpecification(spec) {
                state.specialColors.setOverride(slot, to: color)
            }
        }
    }

    mutating func resetSpecialColors(_ payload: ArraySlice<UInt8>) {
        guard !payload.isEmpty else {
            state.specialColors.resetAllOverrides()
            return
        }
        var start = payload.startIndex
        while start < payload.endIndex {
            let end = payload[start...].firstIndex(of: 0x3B) ?? payload.endIndex
            if let slot = Self.parseSpecialColorSlot(payload[start..<end]) {
                state.specialColors.resetOverride(slot)
            }
            start = end < payload.endIndex ? payload.index(after: end) : payload.endIndex
        }
    }

    private mutating func reportSpecialColor(_ slot: SpecialColors.Slot) {
        let color = state.specialColors.color(at: slot) ?? (0, 0, 0)
        func channel(_ value: UInt8) -> String {
            let hex = String(value, radix: 16)
            let byte = hex.count == 1 ? "0" + hex : hex
            return byte + byte
        }
        let body = "rgb:\(channel(color.red))/\(channel(color.green))/\(channel(color.blue))"
        state.outputBuffer.append(
            contentsOf: Array("\u{1B}]5;\(slot.rawValue);\(body)\u{1B}\\".utf8))
    }

    private static func parseSpecialColorSlot(_ bytes: ArraySlice<UInt8>) -> SpecialColors.Slot? {
        guard let byte = parseByte(bytes), let slot = SpecialColors.Slot(rawValue: byte) else {
            return nil
        }
        return slot
    }

    /// Bounded before each multiply-add, so hundreds of digits cannot grow
    /// `value` past 255.
    private static func parseByte(_ bytes: ArraySlice<UInt8>) -> UInt8? {
        guard !bytes.isEmpty else { return nil }
        var value = 0
        for byte in bytes {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            let digit = Int(byte - 0x30)
            guard value <= (255 - digit) / 10 else { return nil }
            value = value * 10 + digit
        }
        return UInt8(value)
    }

    /// As xterm: `f` and `ffff` both become 255.
    private static func scaleToByte(_ value: UInt32, hexDigits: Int) -> UInt8 {
        let maximum = (UInt32(1) << (4 * UInt32(hexDigits))) - 1
        guard maximum > 0 else { return 0 }
        return UInt8((value * 255 + maximum / 2) / maximum)
    }

    // MARK: - Kitty keyboard protocol

    /// Only honoured flags: a program told it has event reporting would encode
    /// releases nobody sends.
    mutating func reportKeyboardProtocol() {
        let flags = state.keyboardProtocol.current.rawValue
        state.outputBuffer.append(contentsOf: Array("\u{1B}[?\(flags)u".utf8))
    }

    mutating func pushKeyboardProtocol(_ parameters: Parameters) {
        state.keyboardProtocol.push(
            KeyboardEnhancementFlags(rawValue: UInt8(min(255, parameters.value(0, default: 0)))))
    }

    mutating func popKeyboardProtocol(_ parameters: Parameters) {
        state.keyboardProtocol.pop(parameters.value(0, default: 1))
    }

    mutating func setKeyboardProtocol(_ parameters: Parameters) {
        state.keyboardProtocol.set(
            KeyboardEnhancementFlags(rawValue: UInt8(min(255, parameters.value(0, default: 0)))),
            mode: parameters.value(1, default: 1))
    }

    /// DECSCL. The 7/8-bit parameter is ignored: Corta always emits 7-bit.
    mutating func setConformanceLevel(_ parameters: Parameters) {
        let level = parameters.value(0, default: 65)
        guard (61...65).contains(level) else { return }
        state.conformanceLevel = level
    }
}
