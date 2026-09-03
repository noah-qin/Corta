import CortaTerminal
import simd

/// Maps a `CortaTerminal.Color` to sRGB-encoded RGBA floats for the quad
/// pipeline: the 16 indexed colours from the active theme, and the 6×6×6
/// colour cube and 24-step greyscale ramp that `Color.indexed` describes.
///
/// The cube and the ramp are deliberately *not* themed. xterm defines them
/// numerically, so a program asking for colour 137 means one specific
/// colour; only the low 16 and the terminal's own three (foreground,
/// background, cursor) are a matter of taste. Colours a program sends as
/// 24-bit values do not come through here at all.
///
/// The values are sRGB, and the drawable is tagged sRGB in `TerminalView`;
/// untagged, they were interpreted in the display's own space and rendered
/// oversaturated on a P3 screen.
nonisolated enum TerminalColorPalette {
    /// The live variant — the chosen theme (M6.2) resolved for the current
    /// appearance (M6.13). `nonisolated(unsafe)` because this is read from
    /// the renderer, which is nonisolated by design; every write goes
    /// through `apply(_:)` on the main thread, and every read happens on the
    /// main thread too (the render loop runs off the display link). It is a
    /// plain value with no interior mutability, so a read can never see a
    /// half-written theme.
    private nonisolated(unsafe) static var active: Theme.Variant = Theme.corta.dark

    /// Swaps the live variant. Called when the theme or the system
    /// appearance changes; the panes redraw themselves afterwards.
    static func apply(_ variant: Theme.Variant) { active = variant }

    static var defaultForeground: SIMD4<Float> { active.foreground }
    static var defaultBackground: SIMD4<Float> { active.background }
    static var cursorColor: SIMD4<Float> { active.cursor }

    /// Opaque. The terminal canvas is the *content* layer, not a glass
    /// surface — see the structure note in `ViewController`. Content that is
    /// translucent over glass pays for it in contrast: at 0.72 every colour
    /// lost a fifth of its ratio against the background, which reads as the
    /// whole screen being washed out. Lowering this is all it takes to bring
    /// translucency back; the window and layer already permit it.
    static let backgroundOpacity: Float = 1.0

    static var clearColor: SIMD4<Float> {
        let c = defaultBackground
        return SIMD4<Float>(
            c.x * backgroundOpacity, c.y * backgroundOpacity, c.z * backgroundOpacity,
            backgroundOpacity)
    }

    private static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> SIMD4<Float> {
        SIMD4<Float>(Float(r) / 255, Float(g) / 255, Float(b) / 255, 1)
    }

    /// The colour a cell would show if it *is* the foreground, i.e. resolves
    /// `.default` to `defaultForeground` rather than `defaultBackground`.
    static func resolveForeground(_ color: Color) -> SIMD4<Float> {
        color.isDefault ? defaultForeground : resolve(color)
    }

    static func resolveBackground(_ color: Color) -> SIMD4<Float> {
        color.isDefault ? defaultBackground : resolve(color)
    }

    private static func resolve(_ color: Color) -> SIMD4<Float> {
        if let components = color.components {
            return rgb(components.red, components.green, components.blue)
        }
        guard let index = color.index else { return defaultForeground }
        if index < 16 { return active.ansi[Int(index)] }
        if index < 232 {
            let i = Int(index) - 16
            let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
            return rgb(levels[i / 36], levels[(i / 6) % 6], levels[i % 6])
        }
        let level = 8 + (Int(index) - 232) * 10
        return rgb(UInt8(level), UInt8(level), UInt8(level))
    }
}
