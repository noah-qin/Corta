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

extension Performer {
    mutating func reportColorScheme() {
        state.outputBuffer.append(contentsOf: Array("\u{1B}[?997;\(state.isDark ? 1 : 2)n".utf8))
    }
    mutating func resetDynamicColor(_ code: Int) {
        state.dynamicColorOverrides.remove(code - 100)
        switch code {
        case 110: state.dynamicColors.foreground = state.dynamicColorDefaults.foreground
        case 111: state.dynamicColors.background = state.dynamicColorDefaults.background
        case 112: state.dynamicColors.cursor = state.dynamicColorDefaults.cursor
        case 117: state.selectionBackground = .default
        case 119: state.selectionForeground = .default
        default: break
        }
    }

    /// Fixed table only. Neither unknown nor malformed names are echoed.
    /// Source: xterm ctlseqs, XTGETTCAP; values describe implemented behaviour.
    private static let capabilities: [(String, String)] = [
        ("name", "xterm-256color"), ("TN", "xterm-256color"), ("Co", "256"), ("colors", "256"),
        ("RGB", "8/8/8"),
        ("Ss", "\u{1B}[%p1%d q"), ("Se", "\u{1B}[0 q"),
        ("Smulx", "\u{1B}[4:%p1%dm"),
        ("Setulc", "\u{1B}[58:2::%p1%{65536}%/%d:%p1%{256}%/%{255}%&%d:%p1%{255}%&%dm"),
        ("kbs", "\u{7F}"), ("kcuu1", "\u{1B}OA"), ("kcud1", "\u{1B}OB"),
        ("kcuf1", "\u{1B}OC"), ("kcub1", "\u{1B}OD"), ("khome", "\u{1B}OH"), ("kend", "\u{1B}OF"),
        ("kich1", "\u{1B}[2~"), ("kdch1", "\u{1B}[3~"), ("kpp", "\u{1B}[5~"), ("knp", "\u{1B}[6~"),
        ("smkx", "\u{1B}[?1h\u{1B}="), ("rmkx", "\u{1B}[?1l\u{1B}>"),
        ("ku", "\u{1B}OA"), ("kd", "\u{1B}OB"), ("kr", "\u{1B}OC"), ("kl", "\u{1B}OD"),
        ("kh", "\u{1B}OH"), ("@7", "\u{1B}OF"), ("kb", "\u{7F}"), ("kB", "\u{1B}[Z"),
        ("kcbt", "\u{1B}[Z"),
        ("kI", "\u{1B}[2~"), ("kD", "\u{1B}[3~"), ("kP", "\u{1B}[5~"), ("kN", "\u{1B}[6~"),
        ("kf1", "\u{1B}OP"), ("kf2", "\u{1B}OQ"), ("kf3", "\u{1B}OR"), ("kf4", "\u{1B}OS"),
        ("kf5", "\u{1B}[15~"), ("kf6", "\u{1B}[17~"), ("kf7", "\u{1B}[18~"), ("kf8", "\u{1B}[19~"),
        ("kf9", "\u{1B}[20~"), ("kf10", "\u{1B}[21~"), ("kf11", "\u{1B}[23~"), ("kf12", "\u{1B}[24~"),
        ("civis", "\u{1B}[?25l"), ("cnorm", "\u{1B}[?25h"),
    ]
    private static func hex(_ text: String) -> String {
        text.utf8.map {
            let h = String($0, radix: 16)
            return h.count == 1 ? "0" + h : h
        }.joined()
    }
    private static let capabilityReplies: [String: [UInt8]] = Dictionary(
        uniqueKeysWithValues:
            capabilities.map { name, value in
                (hex(name), Array("\u{1B}P1+r\(hex(name))=\(hex(value))\u{1B}\\".utf8))
            })
    mutating func dcsDispatch(_ bytes: ArraySlice<UInt8>) {
        if state.itermImage != nil { state.itermImage = nil }
        if bytes.starts(with: [0x24, 0x71]) {
            if bytes.dropFirst(2).elementsEqual([0x6D]) {
                reportRendition()
            } else {
                state.outputBuffer.append(contentsOf: Array("\u{1B}P0$r\u{1B}\\".utf8))
            }
            return
        }
        guard bytes.starts(with: [0x2B, 0x71]) else { return }
        for name in bytes.dropFirst(2).split(separator: 0x3B, omittingEmptySubsequences: false) {
            let key = String(decoding: name, as: UTF8.self).lowercased()
            state.outputBuffer.append(
                contentsOf: Self.capabilityReplies[key] ?? Array("\u{1B}P0+r\u{1B}\\".utf8))
        }
    }
    /// Neovim probes a curly underline through DECRQSS SGR before enabling it.
    /// The reply serialises numeric pen state, never the request's bytes.
    private mutating func reportRendition() {
        let pen = grid.pen
        var sgr = ["0"]
        for (flag, code): (CellAttributes, String) in [
            (.bold, "1"), (.dim, "2"), (.italic, "3"),
            (.blink, "5"), (.reverse, "7"), (.invisible, "8"), (.strikethrough, "9"),
        ] {
            if pen.attributes.contains(flag) { sgr.append(code) }
        }
        if pen.attributes.contains(.curlyUnderline) {
            sgr.append("4:3")
        } else if pen.attributes.contains(.doubleUnderline) {
            sgr.append("4:2")
        } else if pen.attributes.contains(.underline) {
            sgr.append("4")
        }
        func color(_ color: Color, code: Int) -> String? {
            if let index = color.index { return "\(code):5:\(index)" }
            if let rgb = color.components { return "\(code):2::\(rgb.red):\(rgb.green):\(rgb.blue)" }
            return nil
        }
        if let value = color(pen.foreground, code: 38) { sgr.append(value) }
        if let value = color(pen.background, code: 48) { sgr.append(value) }
        if let underline = grid.underlineColors.color(for: pen.underlineColorID),
            let value = color(underline, code: 58)
        {
            sgr.append(value)
        }
        state.outputBuffer.append(
            contentsOf: Array("\u{1B}P1$r\(sgr.joined(separator:";"))m\u{1B}\\".utf8))
    }

}
