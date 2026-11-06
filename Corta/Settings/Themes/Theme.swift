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
        func triple(_ color: SIMD4<Float>) -> RGB {
            RGB(red: byte(color.x), green: byte(color.y), blue: byte(color.z))
        }
        var colors = DynamicColors(
            foreground: triple(foreground), background: triple(background), cursor: triple(cursor))
        colors.selection = triple(overlayColors.selection)
        return colors
    }

    /// OSC 4 defaults: indices 0–15 from this variant, 16–255 from
    /// `IndexedPalette.xtermDefaults()` — the formula `resolve(_:)` renders
    /// with. Overrides are painted too, so query and paint always agree.
    var indexedPaletteDefaults: IndexedPalette {
        func byte(_ component: Float) -> UInt8 { UInt8((component * 255).rounded()) }
        func triple(_ color: SIMD4<Float>) -> RGB {
            RGB(red: byte(color.x), green: byte(color.y), blue: byte(color.z))
        }
        var defaults = IndexedPalette.xtermDefaults()
        for (index, color) in ansi.enumerated() where index < 16 {
            defaults[index] = triple(color)
        }
        return IndexedPalette(defaults: defaults)
    }
}

nonisolated extension Theme.Variant {
    /// A dark background, by its luminance.
    var isDarkBackground: Bool {
        0.2126 * background.x + 0.7152 * background.y + 0.0722 * background.z < 0.5
    }

    /// Part of the way to `other`, channel by channel: a theme switch blends
    /// through these rather than jumping.
    func mixed(with other: Theme.Variant, by amount: Float) -> Theme.Variant {
        func mix(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> { a + (b - a) * amount }
        // The ends exactly: a blend's last step is the theme itself.
        if amount <= 0 { return self }
        if amount >= 1 || ansi.count != other.ansi.count { return amount < 0.5 ? self : other }
        return Theme.Variant(
            foreground: mix(foreground, other.foreground), background: mix(background, other.background),
            cursor: mix(cursor, other.cursor), ansi: zip(ansi, other.ansi).map(mix))
    }
}

/// The colours a variant does not name but the renderer paints: highlights
/// and rules over the text. Derived, so a light theme gets a selection
/// chosen for a light background and a custom theme needs no extra keys
/// (`docs/CONFIGURATION.md` §4, "Derived colours").
nonisolated struct OverlayColors: Equatable, Sendable {
    var selection: SIMD4<Float>
    var searchMatch: SIMD4<Float>
    var currentSearchMatch: SIMD4<Float>
    var linkUnderline: SIMD4<Float>
    var markSucceeded: SIMD4<Float>
    var markFailed: SIMD4<Float>
    var markInterrupted: SIMD4<Float>
}

nonisolated extension Theme.Variant {
    /// Translucent fills sit under the glyph, so the text keeps its own
    /// colour; the alphas are what keeps it readable over them.
    ///
    /// - selection: blue (`ansi4`) moved 40% of the way to the foreground,
    ///   at 40% — pure blue at Corta's dark background barely showed (a
    ///   1.2:1 contrast), and a step towards the text colour lifts it on a
    ///   dark theme and keeps it light on a light one
    /// - search match: yellow (`ansi3`) at 35%; the current match at 55%
    /// - hovered-link underline: cyan (`ansi6`), opaque
    /// - prompt marks: green (`ansi2`) at 85% for success, red (`ansi1`) at
    ///   90% for failure, and the midpoint of foreground and background at
    ///   90% for an interrupted command (exit 130) — neither outcome.
    ///
    /// Only the normal eight: Solarized's bright slots are its grey base
    /// tones, not brighter hues.
    var overlayColors: OverlayColors {
        func slot(_ index: Int, alpha: Float) -> SIMD4<Float> {
            var color = index < ansi.count ? ansi[index] : foreground
            color.w = alpha
            return color
        }
        var selection = slot(4, alpha: 1) * 0.6 + foreground * 0.4
        selection.w = 0.4
        var neutral = (foreground + background) / 2
        neutral.w = 0.9
        return OverlayColors(
            selection: selection,
            searchMatch: slot(3, alpha: 0.35),
            currentSearchMatch: slot(3, alpha: 0.55),
            linkUnderline: slot(6, alpha: 1),
            markSucceeded: slot(2, alpha: 0.85),
            markFailed: slot(1, alpha: 0.9),
            markInterrupted: neutral)
    }
}

/// 8-bit sRGB, opaque.
private nonisolated func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> SIMD4<Float> {
    SIMD4<Float>(Float(r) / 255, Float(g) / 255, Float(b) / 255, 1)
}

extension Theme {
    /// The default, over a dark blue-grey surface and white. Every hue in
    /// both variants reads at 4.5:1 or more on its background; bright black,
    /// which shells use for suggestions and comments, stays dimmer by
    /// design. The light variant darkens the bright half rather than
    /// inverting, which gives pastels with no contrast on white.
    nonisolated static let corta = Theme(
        name: "corta",
        displayName: "Corta",
        dark: Variant(
            foreground: rgb(245, 245, 245),
            background: rgb(35, 40, 51),
            cursor: rgb(245, 245, 245),
            ansi: [
                rgb(59, 66, 82), rgb(242, 112, 122), rgb(127, 207, 124), rgb(232, 194, 122),
                rgb(111, 168, 247), rgb(199, 146, 234), rgb(95, 201, 214), rgb(200, 205, 214),
                rgb(122, 130, 148), rgb(255, 138, 147), rgb(155, 228, 148), rgb(245, 214, 143),
                rgb(146, 190, 255), rgb(220, 170, 247), rgb(132, 221, 232), rgb(247, 248, 250),
            ]),
        light: Variant(
            foreground: rgb(38, 42, 51),
            // Pure white: panes are the lightest layer on a grey ground.
            background: rgb(255, 255, 255),
            // A slate grey, not the foreground: a near-black block read as a
            // hole in the page. Still 4.7:1 against the background.
            cursor: rgb(108, 114, 126),
            ansi: [
                rgb(43, 47, 56), rgb(196, 47, 58), rgb(35, 122, 49), rgb(138, 95, 0),
                rgb(45, 91, 203), rgb(146, 53, 184), rgb(14, 115, 128), rgb(107, 112, 121),
                rgb(95, 101, 115), rgb(210, 60, 70), rgb(41, 132, 54), rgb(154, 108, 0),
                rgb(58, 104, 216), rgb(164, 67, 201), rgb(19, 130, 143), rgb(30, 32, 38),
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

    /// Neutral greys with muted hues, held to the same 4.5:1 as the default.
    nonisolated static let mono = Theme(
        name: "mono",
        displayName: "Mono",
        dark: Variant(
            foreground: rgb(225, 225, 225),
            background: rgb(24, 24, 24),
            cursor: rgb(225, 225, 225),
            ansi: [
                rgb(48, 48, 48), rgb(210, 104, 94), rgb(130, 181, 114), rgb(200, 174, 108),
                rgb(126, 159, 207), rgb(177, 132, 189), rgb(114, 179, 184), rgb(200, 200, 200),
                rgb(124, 124, 124), rgb(224, 126, 116), rgb(152, 200, 135), rgb(217, 192, 128),
                rgb(151, 180, 222), rgb(195, 155, 206), rgb(140, 198, 202), rgb(240, 240, 240),
            ]),
        light: Variant(
            foreground: rgb(32, 32, 32),
            background: rgb(250, 250, 250),
            cursor: rgb(32, 32, 32),
            ansi: [
                rgb(20, 20, 20), rgb(168, 59, 48), rgb(47, 118, 56), rgb(128, 95, 18),
                rgb(52, 90, 158), rgb(134, 66, 143), rgb(38, 114, 124), rgb(110, 110, 110),
                rgb(92, 92, 92), rgb(181, 68, 52), rgb(45, 125, 58), rgb(138, 103, 20),
                rgb(61, 99, 170), rgb(146, 71, 156), rgb(41, 123, 133), rgb(10, 10, 10),
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

    /// Offered built-ins, then the user's. The selected themes are always
    /// included, or the settings page would show nothing selected and the
    /// next click would overwrite the user's choice.
    nonisolated static func all(in configuration: Configuration) -> [Theme] {
        let custom = configuration.customThemes
        let customNames = Set(custom.map(\.name))
        var themes = builtIn.filter { !customNames.contains($0.name) } + custom
        for name in [configuration.theme, configuration.darkTheme].compactMap(\.self)
        where !themes.contains(where: { $0.name == name }) {
            if let active = named(name) { themes.append(active) }
        }
        return themes
    }

    /// What the panes draw: the light theme's light variant and the dark
    /// theme's dark one. An unknown name falls back to the default.
    nonisolated static func selected(in configuration: Configuration) -> Theme {
        let light = named(configuration.theme, in: configuration) ?? .corta
        guard let darkName = configuration.darkTheme else { return light }
        let dark = named(darkName, in: configuration) ?? .corta
        guard dark.name != light.name else { return light }
        return Theme(
            name: configuration.themeChoice, displayName: light.displayName + " / " + dark.displayName,
            dark: dark.dark, light: light.light)
    }
}

// MARK: - The choice in the file

nonisolated extension Configuration {
    /// The `theme` value: one name for both appearances, or
    /// `light:<name>,dark:<name>` for two. Nil for anything else; a side
    /// left out is the default theme.
    static func themeChoice(_ value: String) -> (light: String, dark: String?)? {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard value.contains(":") else { return (value.isEmpty ? Theme.corta.name : value, nil) }
        var light: String?
        var dark: String?
        for part in value.split(separator: ",", omittingEmptySubsequences: false) {
            let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, !pair[1].isEmpty else { return nil }
            switch pair[0] {
            case "light" where light == nil: light = pair[1]
            case "dark" where dark == nil: dark = pair[1]
            default: return nil
            }
        }
        let lightName = light ?? Theme.corta.name
        let darkName = dark ?? Theme.corta.name
        return (lightName, darkName == lightName ? nil : darkName)
    }

    /// As `theme` is written: one name while both appearances share it.
    var themeChoice: String {
        guard let darkTheme, darkTheme != theme else { return theme }
        return "light:\(theme),dark:\(darkTheme)"
    }

    /// The theme named for one appearance.
    func themeName(dark: Bool) -> String { dark ? darkTheme ?? theme : theme }

    /// Chooses the theme for one appearance and leaves the other as it was.
    mutating func setTheme(_ name: String, dark: Bool) {
        let other = themeName(dark: !dark)
        theme = dark ? other : name
        let darkName = dark ? name : other
        darkTheme = darkName == theme ? nil : darkName
    }

    /// One theme for both appearances, as the View menu chooses.
    mutating func setTheme(_ name: String) {
        theme = name
        darkTheme = nil
    }
}

// MARK: - User-defined themes

extension Theme {
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
