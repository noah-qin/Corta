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
    /// DECSET/DECRST: only what the app reads is tracked; the rest is ignored
    /// cleanly (`SECURITY.md` §3).
    mutating func applyPrivateModes(_ parameters: Parameters, enabled: Bool) {
        var index = 0
        while index < parameters.count {
            switch parameters[index] {
            case 1:  // DECCKM — application cursor keys
                state.applicationCursorKeysEnabled = enabled
            case 2004:  // bracketed paste
                state.bracketedPasteEnabled = enabled
            case 1000, 1002, 1003:
                if let mode = MouseTrackingMode(rawValue: Int(parameters[index])) {
                    if enabled { state.mouseTrackingMode = mode }
                    else if state.mouseTrackingMode == mode { state.mouseTrackingMode = .off }
                }
            case 1006:  // SGR mouse reporting
                state.sgrMouseEncodingEnabled = enabled
            case 2026:  // synchronized output
                if enabled, !state.synchronizedOutputEnabled {
                    state.synchronizedOutputEpisode &+= 1
                }
                state.synchronizedOutputEnabled = enabled
            case 1004:  // focus reporting
                state.focusReportingEnabled = enabled
            case 1007:  // alternate scroll
                state.alternateScrollEnabled = enabled
            case 45:  // reverse-wraparound mode — not DECBKM, which is ?67
                grid.reverseWraparoundEnabled = enabled
            default:
                break
            }
            index += 1
        }
    }

    /// SM/RM. IRM and LNM are implemented. KAM (keyboard lock) is not: a byte
    /// from a runaway child could wedge input, indistinguishable from a hang.
    /// SRM (local echo) is not: Corta never echoes keystrokes itself. DECRQM
    /// reports both as permanently reset.
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

    /// `false` when no parameter is this handler's. Only `?1049`: `?47`/`?1047`
    /// keep the alternate screen's contents, which this grid discards — half
    /// right is worse than a clean ignore.
    mutating func performAlternateScreenMode(final: UInt8, parameters: Parameters) -> Bool {
        let set: Bool
        switch final {
        case 0x68: set = true   // DECSET
        case 0x6C: set = false  // DECRST
        default: return false
        }
        var handled = false
        for index in 0..<parameters.count {
            if parameters[index] == 1049 {
                if set {
                    if !grid.isAlternateScreenActive {
                        state.parkedMainKeyboardProtocol = state.keyboardProtocol
                        state.keyboardProtocol = KeyboardProtocolStack()
                    }
                    state.directoryCompletion = nil
                    grid.enterAlternateScreen()
                } else {
                    if let main = state.parkedMainKeyboardProtocol {
                        state.keyboardProtocol = main
                        state.parkedMainKeyboardProtocol = nil
                    }
                    grid.exitAlternateScreen()
                    applyRowRemaps()
                }
                handled = true
            }
        }
        return handled
    }
}
