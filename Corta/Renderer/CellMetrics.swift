import CoreGraphics
import CoreText

/// The pixel geometry a monospaced font imposes on the grid: how wide and
/// tall one cell is, and where the baseline sits inside it.
///
/// Derived once per font, not per frame or per glyph — every cell in the
/// grid uses the same box, which is the entire point of a monospaced
/// terminal font.
nonisolated struct CellMetrics {
    var cellWidth: CGFloat
    var cellHeight: CGFloat
    /// Distance from a cell's top edge down to the baseline.
    var baselineOffset: CGFloat

    /// The same box in device pixels. Derived by multiplying rather than by
    /// re-measuring a larger font, so a pixel cell is always exactly `scale`
    /// point cells and the grid never drifts out of alignment.
    func scaled(by scale: CGFloat) -> CellMetrics {
        var copy = self
        copy.cellWidth *= scale
        copy.cellHeight *= scale
        copy.baselineOffset *= scale
        return copy
    }

    /// - Parameter scale: the backing scale the cell will be rasterised at.
    ///   The box is snapped to whole *device pixels*, not whole points, so
    ///   `scaled(by: scale)` still lands on integers — glyphs stay on the
    ///   pixel grid — without the point box jumping a whole point at a time.
    ///
    ///   Whole-point snapping is what made the font-size shortcuts change
    ///   the window's aspect ratio unevenly. SF Mono's advance is 0.6 x the
    ///   size, so ceil() gave 9pt for both 14pt and 15pt text while the line
    ///   height went 17 to 18:
    ///   one press grew the window in both axes, the next only in height,
    ///   and the cell's own proportions swung ~7% either side of the font's
    ///   with it. At 2x the same rounding costs at most half a point.
    init(font: CTFont, scale: CGFloat = 1) {
        // 'M' is representative of a monospaced font's advance; every glyph
        // in a true monospace font has the same one, but asking rather than
        // assuming avoids surprises with fonts that are only "mostly" fixed.
        var glyph: CGGlyph = 0
        var mChar: UniChar = UniChar(UnicodeScalar("M").value)
        CTFontGetGlyphsForCharacters(font, &mChar, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)

        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)

        let pixels = max(1, scale)
        func snapUp(_ points: CGFloat) -> CGFloat { (points * pixels).rounded(.up) / pixels }
        func snapNearest(_ points: CGFloat) -> CGFloat { (points * pixels).rounded() / pixels }

        let advanceWidth = advance.width > 0 ? advance.width : CTFontGetSize(font) * 0.6
        let lineHeight = ascent + descent + leading

        // Terminal.app fits SF Mono 12 into a 7pt column on a Retina display.
        // Its nominal advance is 7.418pt; rounding that up to 7.5pt makes a
        // 120-column window 60pt wider and stretches cell-built artwork such
        // as Claude Code's logo. Snap down by at most one device pixel to
        // match Terminal's column geometry. The glyph ink itself is narrower
        // than the nominal advance, so adjacent cells do not collide.
        self.cellWidth = max(1 / pixels, (advanceWidth * pixels).rounded(.down) / pixels)
        // Width no longer inflates the row. The height follows the font's
        // own line metrics independently, which is also what lets 120x30
        // match Terminal in both axes.
        self.cellHeight = snapUp(lineHeight)
        // The baseline moves with the row: the extra height is leading, and
        // splitting it evenly keeps the glyph centred rather than letting it
        // ride the top of a taller cell.
        self.baselineOffset = snapNearest(ascent + (cellHeight - lineHeight) / 2)
    }
}
