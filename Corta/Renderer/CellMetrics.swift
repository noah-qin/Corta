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

    init(font: CTFont) {
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

        self.cellWidth = advance.width > 0 ? advance.width.rounded(.up) : CTFontGetSize(font) * 0.6
        self.cellHeight = (ascent + descent + leading).rounded(.up)
        self.baselineOffset = ascent.rounded(.up)
    }
}
