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

    /// Every theme the settings page offers, in the order it lists them.
    nonisolated static let builtIn: [Theme] = [.corta, .solarized, .mono]

    nonisolated static func named(_ name: String) -> Theme? {
        builtIn.first { $0.name == name }
    }
}
