import AppKit
import CortaTerminal
import simd

/// M6.2 — a colour theme: the sixteen ANSI colours plus the three the
/// terminal itself owns (default foreground, default background, cursor).
///
/// A value, not a namespace. Themes are chosen from the settings page and
/// swapped at runtime, and every pane in every window has to follow the swap
/// — which a `static let` table cannot do. The 6x6x6 cube and the greyscale
/// ramp are *not* part of a theme: xterm defines them numerically, and a
/// program asking for colour 137 means one specific colour, not "whatever
/// this theme thinks".
///
/// M6.13 — a theme carries a light and a dark variant. macOS switching
/// appearance switches which one is live, in every open window, without a
/// restart.
nonisolated struct Theme: Equatable, Sendable {
    /// The name the config file and the settings page use.
    let name: String
    /// The name shown in the settings page's list.
    let displayName: String
    let dark: Variant
    let light: Variant

    /// One appearance's worth of colour.
    struct Variant: Equatable, Sendable {
        var foreground: SIMD4<Float>
        var background: SIMD4<Float>
        var cursor: SIMD4<Float>
        /// The sixteen ANSI colours, in the usual order: black, red, green,
        /// yellow, blue, magenta, cyan, white, then the eight bright ones.
        var ansi: [SIMD4<Float>]
    }

    func variant(dark isDark: Bool) -> Variant { isDark ? dark : light }
}

/// A colour literal for the theme tables: 8-bit sRGB, opaque.
private nonisolated func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> SIMD4<Float> {
    SIMD4<Float>(Float(r) / 255, Float(g) / 255, Float(b) / 255, 1)
}

extension Theme {
    /// The default. Terminal.app's "Basic" sixteen — vivid on purpose,
    /// because the reference this terminal gets compared against is the one
    /// macOS ships — over a dark blue surface at Terminal's own luminance.
    ///
    /// The light variant is not the dark one inverted: inverting a saturated
    /// dark palette gives pastels with no contrast on white. The bright half
    /// is darkened instead, which is what a light terminal theme actually
    /// needs.
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

    /// The classic, both halves as Ethan Schoonover published them.
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

    /// Neutral greys — for anyone who finds the default's blue surface and
    /// vivid ANSI set too much.
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

    /// The theme Corta *offers*: one, listed in the settings page and the
    /// View menu.
    ///
    /// Shipping three meant shipping two that had never been looked at in
    /// anger — a theme is nineteen colours in two variants, and "it parses"
    /// is not the same as "it reads well at 12pt on a laptop panel for eight
    /// hours". One theme that is right is a better first release than three
    /// of which two are guesses.
    ///
    /// This is a presentation decision, not a deletion: `solarized` and
    /// `mono` stay defined and stay resolvable by name below, so a config
    /// file that already says `theme = solarized` keeps working and
    /// `theme.<name>.inherit = solarized` still has something to inherit
    /// from (M7.6). Promoting one back into the offered list is one entry
    /// here.
    nonisolated static let builtIn: [Theme] = [.corta]

    /// Every theme this binary can resolve by name, offered or not. Wider
    /// than `builtIn` on purpose — see the note there.
    nonisolated static let known: [Theme] = [.corta, .solarized, .mono]

    nonisolated static func named(_ name: String) -> Theme? {
        known.first { $0.name == name }
    }

    /// A built-in *or* user-defined theme (M7.6). Custom themes win on a
    /// name collision: a user who names their theme `corta` has said what
    /// they want, and silently ignoring it would be the more surprising rule.
    nonisolated static func named(_ name: String, in configuration: Configuration) -> Theme? {
        configuration.customThemes.first { $0.name == name } ?? named(name)
    }

    /// Every theme available under `configuration`, in list order: the
    /// offered built-ins first, then the user's own.
    ///
    /// The theme the file currently selects is always in the list, even when
    /// it is one of the unoffered built-ins. Otherwise a config that says
    /// `theme = solarized` would leave the settings popup with nothing
    /// selected, and the next click on any control in the page would write
    /// the first item back over the user's choice.
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

// MARK: - User-defined themes (M7.6)

extension Theme {
    /// A theme built from config-file keys, with anything unspecified taken
    /// from `base`.
    ///
    /// Inheriting rather than requiring all nineteen colours is what makes
    /// the feature usable: overriding a background and a cursor is the common
    /// case, and demanding a full ANSI table for it would mean nobody does
    /// it. It also means a half-written theme still renders — a config file
    /// is hand-edited, and a partially-typed one must not black out the
    /// terminal.
    nonisolated static func custom(
        name: String, displayName: String, base: Theme, dark: Variant, light: Variant
    ) -> Theme {
        Theme(name: name, displayName: displayName, dark: dark, light: light)
    }

    /// `#rgb` or `#rrggbb`, the two notations a person actually types. Also
    /// accepts them without the `#`, because half the palettes on the web are
    /// written that way.
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

    /// The `#rrggbb` a colour serialises back as.
    nonisolated static func hex(_ color: SIMD4<Float>) -> String {
        func byte(_ value: Float) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(color.x), byte(color.y), byte(color.z))
    }
}
