import CoreGraphics
import CoreText
import Testing

@testable import Corta

/// The cell box is snapped up to whole *device pixels*, not whole points.
/// Whole-point snapping quantised the width so coarsely that consecutive
/// font sizes shared one: pressing the zoom shortcut grew the window in
/// both axes, then in height alone, alternating as the ceiling happened to
/// land — which is what the user saw as the window changing shape.
struct CellMetricsTests {
    private static let sizes: [CGFloat] = Array(stride(from: 8, through: 32, by: 1))

    private static func metrics(atSize size: CGFloat, scale: CGFloat) -> CellMetrics {
        CellMetrics(font: TerminalFont.primary(ofSize: size), scale: scale)
    }

    /// 2x only, deliberately. A 1x display has nothing finer than a whole
    /// point to snap to, so there the coarse quantisation is the best
    /// available; every Mac this targets is Retina.
    @Test("every font-size step widens the cell, not just its height")
    func widthAdvancesWithEverySizeStep() {
        for (smaller, larger) in zip(Self.sizes, Self.sizes.dropFirst()) {
            let low = Self.metrics(atSize: smaller, scale: 2)
            let high = Self.metrics(atSize: larger, scale: 2)
            #expect(
                high.cellWidth > low.cellWidth,
                "\(smaller)pt -> \(larger)pt left the width at \(low.cellWidth)")
            #expect(high.cellHeight > low.cellHeight)
        }
    }

    /// The grid's alignment invariant: a pixel cell is exactly `scale` point
    /// cells, and it lands on whole pixels so glyphs are not resampled.
    @Test("the point box scales to a whole number of pixels")
    func pixelBoxIsIntegral() {
        for scale in [CGFloat(2), 1] {
            for size in Self.sizes {
                let pixels = Self.metrics(atSize: size, scale: scale).scaled(by: scale)
                #expect(pixels.cellWidth == pixels.cellWidth.rounded())
                #expect(pixels.cellHeight == pixels.cellHeight.rounded())
                #expect(pixels.baselineOffset == pixels.baselineOffset.rounded())
            }
        }
    }

    /// Terminal.app packs SF Mono into the device pixel below its nominal
    /// advance. The adjustment is bounded to one pixel, so it fixes the
    /// 120-column geometry without arbitrarily squeezing the face.
    @Test("column width snaps down by less than one device pixel")
    func snappingStaysWithinOnePixel() {
        let scale: CGFloat = 2
        for size in Self.sizes {
            let font = TerminalFont.primary(ofSize: size)
            var glyph: CGGlyph = 0
            var mChar = UniChar(UnicodeScalar("M").value)
            CTFontGetGlyphsForCharacters(font, &mChar, &glyph, 1)
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            let width = Self.metrics(atSize: size, scale: scale).cellWidth
            #expect(width <= advance.width)
            #expect(advance.width - width < 1 / scale)
        }
    }
}
