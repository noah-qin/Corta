import CortaTerminal
import simd

/// Maps a `CortaTerminal.Color` to sRGB-encoded RGBA floats for the quad
/// pipeline: the 16 indexed colours, the 6×6×6 colour cube and the 24-step
/// greyscale ramp that `Color.indexed` describes.
///
/// The 16 are Terminal.app's, not xterm's — this comment used to claim
/// xterm over a table of VS Code Dark+ values, and neither matched what the
/// terminal was being compared against.
///
/// The values are sRGB, and the drawable is tagged sRGB in `TerminalView`;
/// untagged, they were interpreted in the display's own space and rendered
/// oversaturated on a P3 screen.
nonisolated enum TerminalColorPalette {
    static let defaultForeground = SIMD4<Float>(0.898, 0.898, 0.898, 1)
    /// A soft black rather than pure black — the tone Terminal.app's dark
    /// profiles have, without the hard contrast of pure #000.
    ///
    /// Opaque. Translucency reads as depth on an empty desktop and as noise
    /// over a window full of text, and the terminal has to stay readable
    /// over anything. Lowering this constant is all it takes to bring it
    /// back; the window and layer already permit it.
    static let backgroundOpacity: Float = 0.72
    static let defaultBackground = SIMD4<Float>(
        40.0 / 255, 42.0 / 255, 47.0 / 255, backgroundOpacity)
    static var clearColor: SIMD4<Float> {
        let c = defaultBackground
        return SIMD4<Float>(c.x * c.w, c.y * c.w, c.z * c.w, c.w)
    }

    /// Terminal.app's "Basic" profile. Vivid on purpose: the VS Code Dark+
    /// set that was here reads noticeably flat beside it, and the reference
    /// this terminal gets compared against is the one macOS ships.
    ///
    /// Colours a program sends as 24-bit values do not come through here at
    /// all — those are exact, and match Terminal.app channel for channel.
    private static let ansi16: [SIMD4<Float>] = [
        rgb(0, 0, 0), rgb(194, 54, 33), rgb(37, 188, 36), rgb(173, 173, 39),
        rgb(73, 46, 225), rgb(211, 56, 211), rgb(51, 187, 200), rgb(203, 204, 205),
        rgb(129, 131, 131), rgb(252, 57, 31), rgb(49, 231, 34), rgb(234, 236, 35),
        rgb(88, 51, 255), rgb(249, 53, 248), rgb(20, 240, 240), rgb(233, 235, 235),
    ]

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
        if index < 16 { return ansi16[Int(index)] }
        if index < 232 {
            let i = Int(index) - 16
            let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
            return rgb(levels[i / 36], levels[(i / 6) % 6], levels[i % 6])
        }
        let level = 8 + (Int(index) - 232) * 10
        return rgb(UInt8(level), UInt8(level), UInt8(level))
    }
}
