import CortaTerminal
import simd

/// Maps a `CortaTerminal.Color` to sRGB-encoded RGBA floats for the quad
/// pipeline. The default xterm 16-colour table, the 6×6×6 colour cube and
/// the 24-step greyscale ramp that `Color.indexed` describes.
nonisolated enum TerminalColorPalette {
    static let defaultForeground = SIMD4<Float>(0.898, 0.898, 0.898, 1)
    static let defaultBackground = SIMD4<Float>(0, 0, 0, 1)

    private static let ansi16: [SIMD4<Float>] = [
        rgb(0, 0, 0), rgb(205, 49, 49), rgb(13, 188, 121), rgb(229, 229, 16),
        rgb(36, 114, 200), rgb(188, 63, 188), rgb(17, 168, 205), rgb(229, 229, 229),
        rgb(102, 102, 102), rgb(241, 76, 76), rgb(35, 209, 139), rgb(245, 245, 67),
        rgb(59, 142, 234), rgb(214, 112, 214), rgb(41, 184, 219), rgb(255, 255, 255),
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
