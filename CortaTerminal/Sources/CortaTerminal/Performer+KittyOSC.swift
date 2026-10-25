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

import Foundation

/// Fixed protocol vocabulary, never a program-supplied name in a reply.
struct PointerShapeStack: Sendable {
    static let names = ["alias", "cell", "copy", "crosshair", "default", "e-resize", "ew-resize",
        "grab", "grabbing", "help", "move", "n-resize", "ne-resize", "nesw-resize", "no-drop",
        "not-allowed", "ns-resize", "nw-resize", "nwse-resize", "pointer", "progress", "s-resize",
        "se-resize", "sw-resize", "text", "vertical-text", "w-resize", "wait", "zoom-in", "zoom-out"]
    static let aliases = ["xterm": "text", "hand1": "pointer", "hand2": "pointer", "left_ptr": "default",
        "watch": "wait", "cross": "crosshair", "fleur": "move", "sb_h_double_arrow": "ew-resize",
        "sb_v_double_arrow": "ns-resize"]
    var shapes: [String] = []
    var current: String? { shapes.last }
    static func canonical(_ name: String) -> String? {
        names.first { $0 == name } ?? aliases[name]
    }
    mutating func handle(_ text: String) -> String? {
        let operation = text.first
        let hasOperation = operation.map { "=<>?".contains($0) } ?? false
        let names = (hasOperation ? String(text.dropFirst()) : text).split(separator: ",", omittingEmptySubsequences: false)
        if operation == "?" {
            return names.map { name in
                switch name {
                case "__current__": return current ?? "0"
                case "__default__", "__grabbed__": return "default"
                default: return Self.canonical(String(name)) == nil ? "0" : "1"
                }
            }.joined(separator: ",")
        }
        if operation == "<" { if !shapes.isEmpty { shapes.removeLast() }; return nil }
        if text.isEmpty || text == "=" { shapes = []; return nil }
        if operation != ">", !shapes.isEmpty { shapes.removeLast() }
        for name in names {
            shapes.append(Self.canonical(String(name)) ?? "default")
            if shapes.count > 16 { shapes.removeFirst() }
        }
        return nil
    }
}

extension Performer {
    mutating func pointerShape(_ payload: ArraySlice<UInt8>) {
        let text = String(decoding: payload, as: UTF8.self)
        let reply = grid.isAlternateScreenActive ? state.pointerAlternate.handle(text) : state.pointerMain.handle(text)
        if let reply { state.outputBuffer += Array("\u{1B}]22;\(reply)\u{1B}\\".utf8) }
    }

    private static let kittyColorKeys = ["foreground": 10, "background": 11, "cursor": 12,
        "selection_background": 17, "selection_foreground": 19, "cursor_text": 20]

    mutating func kittyColors(_ payload: ArraySlice<UInt8>) {
        var replies: [String] = []
        for field in String(decoding: payload, as: UTF8.self).split(separator: ";") {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let requestedKey = String(parts[0])
            let code = Self.kittyColorKeys[requestedKey]
            let index = UInt8(requestedKey)
            guard code != nil || index != nil else { continue }
            // Rebuild even palette keys from numbers; never reflect the input.
            let key = code.flatMap { c in Self.kittyColorKeys.first { $0.value == c }?.key } ?? String(index!)
            let value = parts.count == 2 ? String(parts[1]) : ""
            if value == "?" {
                let color: (red: UInt8, green: UInt8, blue: UInt8)?
                switch code {
                case 10: color = state.dynamicColors.foreground
                case 11: color = state.dynamicColors.background
                case 12: color = state.dynamicColors.cursor
                case 17: color = state.selectionBackground.components
                case 19: color = state.selectionForeground.components
                case 20: color = state.dynamicColors.cursorText.components
                default: color = state.indexedPalette.color(at: index!)
                }
                replies.append(key + "=" + (color.map(Self.colorReport) ?? ""))
            } else if value.isEmpty {
                if let index { state.indexedPalette.resetOverride(index) }
                else if code == 20 { state.dynamicColors.cursorText = .default }
                else { resetDynamicColor(code! + 100) }
            } else if code == 20 {
                if let color = Self.parseColorSpecification(Array(value.utf8)[...]) {
                    state.dynamicColors.cursorText = .rgb(color.red, color.green, color.blue)
                }
            } else if let code { setDynamicColor(code, specification: Array(value.utf8)[...]) }
            else if let index, let color = Self.parseColorSpecification(Array(value.utf8)[...]) {
                state.indexedPalette.setOverride(index, to: color)
            }
        }
        if !replies.isEmpty { state.outputBuffer += Array(("\u{1B}]21;" + replies.joined(separator: ";") + "\u{1B}\\").utf8) }
    }
}
