import simd

/// Block elements (U+2580–U+259F) drawn as geometry rather than glyphs.
///
/// A cell is `advance.rounded(.up)` wide, so a font whose advance is 8.4pt
/// gets a 9pt cell and every glyph leaves a point of background bare on its
/// right. Between letters that is invisible. Between block characters it is a
/// grid of gaps: measured, `U+2588 FULL BLOCK` inked 88% of its cell, and the
/// cell's average colour fell from the requested (255,140,0) to (203,111,0) —
/// an orange that reads as pink once the background mixes in. Claude Code's
/// banner is drawn with these, which is exactly how it looked.
///
/// No font's metrics tile reliably after that rounding, so kitty, Ghostty and
/// Alacritty all synthesise this range instead of shaping it. This does the
/// same: each scalar maps to rectangles in unit cell space, scaled to the
/// cell at draw time, so they meet exactly.
nonisolated enum BlockElements {
    /// A rectangle in unit cell space — x, y, width, height in 0...1, with y
    /// measured downward from the cell's top, matching the shader's pixel
    /// space — and the coverage to draw it at.
    struct Piece {
        var rect: SIMD4<Float>
        var alpha: Float
    }

    /// The pieces for `scalar`, or nil if it is not a block element and
    /// should be shaped normally.
    static func pieces(for scalar: UInt32) -> [Piece]? {
        func solid(_ x: Float, _ y: Float, _ w: Float, _ h: Float, _ a: Float = 1) -> [Piece] {
            [Piece(rect: SIMD4<Float>(x, y, w, h), alpha: a)]
        }
        switch scalar {
        case 0x2580: return solid(0, 0, 1, 0.5)            // ▀ upper half
        case 0x2581...0x2587:                              // ▁▂▃▄▅▆▇ lower eighths
            let eighths = Float(scalar - 0x2580)
            let h = eighths / 8
            return solid(0, 1 - h, 1, h)
        case 0x2588: return solid(0, 0, 1, 1)              // █ full
        case 0x2589...0x258F:                              // ▉▊▋▌▍▎▏ left eighths
            let w = Float(0x2590 - scalar) / 8
            return solid(0, 0, w, 1)
        case 0x2590: return solid(0.5, 0, 0.5, 1)          // ▐ right half
        case 0x2591: return solid(0, 0, 1, 1, 0.25)        // ░ light shade
        case 0x2592: return solid(0, 0, 1, 1, 0.5)         // ▒ medium shade
        case 0x2593: return solid(0, 0, 1, 1, 0.75)        // ▓ dark shade
        case 0x2594: return solid(0, 0, 1, 0.125)          // ▔ upper eighth
        case 0x2595: return solid(0.875, 0, 0.125, 1)      // ▕ right eighth
        case 0x2596...0x259F:                              // quadrants
            // Bit per quadrant: 1 = upper left, 2 = upper right,
            // 4 = lower left, 8 = lower right.
            let masks: [UInt8] = [
                0b0100, 0b1000, 0b0001, 0b1101, 0b1001, 0b0111, 0b1011, 0b0010,
                0b0110, 0b1110,
            ]
            let mask = masks[Int(scalar - 0x2596)]
            var out: [Piece] = []
            if mask & 0b0001 != 0 { out += solid(0, 0, 0.5, 0.5) }
            if mask & 0b0010 != 0 { out += solid(0.5, 0, 0.5, 0.5) }
            if mask & 0b0100 != 0 { out += solid(0, 0.5, 0.5, 0.5) }
            if mask & 0b1000 != 0 { out += solid(0.5, 0.5, 0.5, 0.5) }
            return out
        default: return nil
        }
    }
}
