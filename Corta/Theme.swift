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

import AppKit
import CortaTerminal
import simd

/// A colour theme: the sixteen ANSI colours plus default foreground,
/// background and cursor, in a light and a dark variant that follow the
/// system appearance live. A value, so every pane can follow a swap. The
/// 256-colour cube and grey ramp are xterm's fixed numbers, not themed.
nonisolated struct Theme: Equatable, Sendable {
    /// The name in the config file.
    let name: String
    let displayName: String
    let dark: Variant
    let light: Variant

    struct Variant: Equatable, Sendable {
        var foreground: SIMD4<Float>
        var background: SIMD4<Float>
        var cursor: SIMD4<Float>
        /// Black, red, green, yellow, blue, magenta, cyan, white, then bright.
        var ansi: [SIMD4<Float>]
    }

    func variant(dark isDark: Bool) -> Variant { isDark ? dark : light }
}

nonisolated extension Theme.Variant {
    /// OSC 10/11/12 answers from the live variant, not the other one.
    var dynamicColors: DynamicColors {
        func byte(_ component: Float) -> UInt8 { UInt8((component * 255).rounded()) }
        func triple(_ color: SIMD4<Float>) -> (red: UInt8, green: UInt8, blue: UInt8) {
            (byte(color.x), byte(color.y), byte(color.z))
        }
        return DynamicColors(
            foreground: triple(foreground), background: triple(background),
            cursor: triple(cursor))
    }

    /// OSC 4 defaults: indices 0–15 from this variant, 16–255 from
    /// `IndexedPalette.xtermDefaults()` — the formula `resolve(_:)` renders
    /// with. Overrides are painted too, so query and paint always agree.
    var indexedPaletteDefaults: IndexedPalette {
        func byte(_ component: Float) -> UInt8 { UInt8((component * 255).rounded()) }
        func triple(_ color: SIMD4<Float>) -> (red: UInt8, green: UInt8, blue: UInt8) {
            (byte(color.x), byte(color.y), byte(color.z))
        }
        var defaults = IndexedPalette.xtermDefaults()
        for (index, color) in ansi.enumerated() where index < 16 {
            defaults[index] = triple(color)
        }
        return IndexedPalette(defaults: defaults)
    }
}

/// 8-bit sRGB, opaque.
private nonisolated func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> SIMD4<Float> {
    SIMD4<Float>(Float(r) / 255, Float(g) / 255, Float(b) / 255, 1)
}

extension Theme {
    /// The default: Terminal.app's "Basic" sixteen over a dark blue surface.
    /// The light variant darkens the bright half rather than inverting, which
    /// gives pastels with no contrast on white.
    nonisolated static let corta = Theme(
        name: "corta",
        displayName: "Corta",
        dark: Variant(
            foreground: rgb(245, 245, 245),
            background: rgb(35, 40, 51),
            cursor: rgb(245, 245, 245),
            ansi: [
                rgb(0, 0, 0), rgb(194, 54, 33), rgb(37, 188, 36), rgb(173, 173, 39),
                rgb(73, 46, 225), rgb(211, 56, 211), rgb(51, 187, 200), rgb(203, 204, 205),
                rgb(129, 131, 131), rgb(252, 57, 31), rgb(49, 231, 34), rgb(234, 236, 35),
                rgb(88, 51, 255), rgb(249, 53, 248), rgb(20, 240, 240), rgb(233, 235, 235),
            ]),
        light: Variant(
            foreground: rgb(38, 42, 51),
            background: rgb(252, 252, 250),
            cursor: rgb(38, 42, 51),
            ansi: [
                rgb(0, 0, 0), rgb(170, 34, 20), rgb(24, 132, 24), rgb(140, 108, 20),
                rgb(38, 62, 190), rgb(160, 42, 160), rgb(24, 130, 142), rgb(120, 122, 124),
                rgb(90, 92, 94), rgb(200, 44, 26), rgb(30, 160, 30), rgb(160, 126, 24),
                rgb(52, 78, 220), rgb(190, 50, 190), rgb(28, 152, 166), rgb(30, 32, 34),
            ]))

    /// As Ethan Schoonover published it.
    nonisolated static let solarized = Theme(
        name: "solarized",
        displayName: "Solarized",
        dark: Variant(
            foreground: rgb(131, 148, 150),
            background: rgb(0, 43, 54),
            cursor: rgb(147, 161, 161),
            ansi: [
                rgb(7, 54, 66), rgb(220, 50, 47), rgb(133, 153, 0), rgb(181, 137, 0),
                rgb(38, 139, 210), rgb(211, 54, 130), rgb(42, 161, 152), rgb(238, 232, 213),
                rgb(0, 43, 54), rgb(203, 75, 22), rgb(88, 110, 117), rgb(101, 123, 131),
                rgb(131, 148, 150), rgb(108, 113, 196), rgb(147, 161, 161), rgb(253, 246, 227),
            ]),
        light: Variant(
            foreground: rgb(101, 123, 131),
            background: rgb(253, 246, 227),
            cursor: rgb(88, 110, 117),
            ansi: [
                rgb(238, 232, 213), rgb(220, 50, 47), rgb(133, 153, 0), rgb(181, 137, 0),
                rgb(38, 139, 210), rgb(211, 54, 130), rgb(42, 161, 152), rgb(7, 54, 66),
                rgb(253, 246, 227), rgb(203, 75, 22), rgb(147, 161, 161), rgb(131, 148, 150),
                rgb(101, 123, 131), rgb(108, 113, 196), rgb(88, 110, 117), rgb(0, 43, 54),
            ]))

    /// Neutral greys.
    nonisolated static let mono = Theme(
        name: "mono",
        displayName: "Mono",
        dark: Variant(
            foreground: rgb(225, 225, 225),
            background: rgb(24, 24, 24),
            cursor: rgb(225, 225, 225),
            ansi: [
                rgb(40, 40, 40), rgb(190, 90, 80), rgb(120, 170, 110), rgb(190, 170, 100),
                rgb(110, 140, 190), rgb(170, 120, 180), rgb(110, 170, 175), rgb(200, 200, 200),
                rgb(110, 110, 110), rgb(215, 115, 105), rgb(145, 195, 135), rgb(215, 195, 125),
                rgb(135, 165, 215), rgb(195, 145, 205), rgb(135, 195, 200), rgb(240, 240, 240),
            ]),
        light: Variant(
            foreground: rgb(32, 32, 32),
            background: rgb(250, 250, 250),
            cursor: rgb(32, 32, 32),
            ansi: [
                rgb(20, 20, 20), rgb(160, 60, 50), rgb(50, 120, 60), rgb(140, 110, 30),
                rgb(50, 80, 150), rgb(130, 60, 140), rgb(40, 120, 130), rgb(140, 140, 140),
                rgb(80, 80, 80), rgb(185, 75, 60), rgb(60, 145, 70), rgb(160, 130, 40),
                rgb(60, 95, 175), rgb(150, 75, 160), rgb(50, 140, 150), rgb(10, 10, 10),
            ]))

    /// A small curated choice; custom themes continue to take precedence.
    nonisolated static let builtIn: [Theme] = [.corta, .solarized, .mono]

    /// Every theme resolvable by name, offered or not.
    nonisolated static let known: [Theme] = [.corta, .solarized, .mono]

    nonisolated static func named(_ name: String) -> Theme? {
        known.first { $0.name == name }
    }

    /// Built-in or user-defined; a custom theme wins a name collision.
    nonisolated static func named(_ name: String, in configuration: Configuration) -> Theme? {
        configuration.customThemes.first { $0.name == name } ?? named(name)
    }

    /// Offered built-ins, then the user's. The selected theme is always
    /// included, or the settings popup would show nothing and the next click
    /// would overwrite the user's choice.
    nonisolated static func all(in configuration: Configuration) -> [Theme] {
        let custom = configuration.customThemes
        let customNames = Set(custom.map(\.name))
        var themes = builtIn.filter { !customNames.contains($0.name) } + custom
        if !themes.contains(where: { $0.name == configuration.theme }),
            let active = named(configuration.theme)
        {
            themes.append(active)
        }
        return themes
    }
}

// MARK: - User-defined themes

extension Theme {
    /// A theme from config keys, inheriting the rest from `base`: overriding
    /// two colours is the common case, and a half-typed theme still renders.
    nonisolated static func custom(
        name: String, displayName: String, base: Theme, dark: Variant, light: Variant
    ) -> Theme {
        Theme(name: name, displayName: displayName, dark: dark, light: light)
    }

    /// `#rgb` or `#rrggbb`, with or without the `#`.
    nonisolated static func color(_ text: String) -> SIMD4<Float>? {
        var digits = Substring(text.trimmingCharacters(in: .whitespaces))
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        let characters = Array(digits)
        func value(_ slice: [Character]) -> Float? {
            guard let byte = UInt8(String(slice), radix: 16) else { return nil }
            return Float(byte) / 255
        }
        switch characters.count {
        case 3:
            guard let r = value([characters[0], characters[0]]),
                let g = value([characters[1], characters[1]]),
                let b = value([characters[2], characters[2]])
            else { return nil }
            return SIMD4<Float>(r, g, b, 1)
        case 6:
            guard let r = value(Array(characters[0..<2])),
                let g = value(Array(characters[2..<4])),
                let b = value(Array(characters[4..<6]))
            else { return nil }
            return SIMD4<Float>(r, g, b, 1)
        default:
            return nil
        }
    }

    nonisolated static func hex(_ color: SIMD4<Float>) -> String {
        func byte(_ value: Float) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(color.x), byte(color.y), byte(color.z))
    }
}
