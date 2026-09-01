import CoreGraphics
import CoreText
import Metal
import simd

/// Rasterises glyphs into an `r8Unorm` texture atlas and caches them by
/// scalar and weight.
///
/// **ASCII fast path.** `glyph(forASCII:bold:)` looks the glyph up directly
/// with `CTFontGetGlyphsForCharacters` — no `CTLine`, no shaping. Calling
/// into shaping per line per frame costs milliseconds and blows the frame
/// budget on its own (`PERFORMANCE.md` §2.2); ASCII is the overwhelming
/// majority of terminal content, so it must never pay that cost.
///
/// **Everything else** goes through `glyph(shaping:bold:)`, which shapes via
/// `CTLine` once per (scalar, weight) and caches the result forever after —
/// paid once, not per frame.
///
/// Atlas eviction (LRU or multiple pages, `DESIGN.md` §7 hard part 4) is not
/// implemented: M1's own content (ASCII shell output) fits a single
/// 2048×2048 page many times over. Revisit when M3 brings sustained CJK.
nonisolated final class GlyphAtlas {
    struct GlyphKey: Hashable {
        var scalar: UInt32
        var bold: Bool
    }

    struct GlyphInfo {
        /// Atlas UV rect: (x, y, width, height), normalised to [0, 1].
        var uvRect: SIMD4<Float>
        /// Bitmap size, in pixels.
        var size: SIMD2<Float>
        /// Offset from the cell's top-left to the bitmap's top-left, pixels.
        var bearing: SIMD2<Float>
    }

    static let atlasSize = 2048

    private(set) var texture: MTLTexture
    private let font: CTFont
    private let boldFont: CTFont
    private var cache: [GlyphKey: GlyphInfo] = [:]
    private var nextOrigin = (x: 0, y: 1)  // row 0 is reserved: see `solidWhiteUV`
    private var rowHeight = 1

    /// Counters for tests only: prove the ASCII path never shapes.
    private(set) var fastPathHits = 0
    private(set) var shapingHits = 0

    /// A 1×1 fully-opaque texel at the atlas origin, sampled by cursor and
    /// selection quads so they can share the glyph pipeline instead of a
    /// third one.
    static let solidWhiteUV = SIMD4<Float>(0, 0, 0, 0)

    init(device: MTLDevice, font: CTFont) {
        self.font = font
        self.boldFont = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitBold, .traitBold) ?? font

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: Self.atlasSize, height: Self.atlasSize, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .managed
        self.texture = device.makeTexture(descriptor: descriptor)!

        var white: UInt8 = 255
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 1)
    }

    /// ASCII fast path — see the type comment.
    func glyph(forASCII scalar: UInt32, bold: Bool) -> GlyphInfo? {
        let key = GlyphKey(scalar: scalar, bold: bold)
        if let cached = cache[key] { return cached }
        var utf16 = [UniChar(scalar)]
        var glyphs: [CGGlyph] = [0]
        let f = bold ? boldFont : font
        guard CTFontGetGlyphsForCharacters(f, &utf16, &glyphs, 1) else { return nil }
        fastPathHits += 1
        guard glyphs[0] != 0 else { return nil }
        return rasterize(glyph: glyphs[0], font: f, key: key)
    }

    /// Non-ASCII path — shapes via `CTLine`, once per key.
    func glyph(shaping scalar: UInt32, bold: Bool) -> GlyphInfo? {
        let key = GlyphKey(scalar: scalar, bold: bold)
        if let cached = cache[key] { return cached }
        guard let scalarValue = Unicode.Scalar(scalar) else { return nil }
        shapingHits += 1
        let f = bold ? boldFont : font
        let string = String(Character(scalarValue)) as CFString
        let attributed = CFAttributedStringCreate(nil, string, [kCTFontAttributeName: f] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        guard let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first, CTRunGetGlyphCount(run) > 0
        else { return nil }
        var glyph: CGGlyph = 0
        CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
        guard glyph != 0 else { return nil }
        return rasterize(glyph: glyph, font: f, key: key)
    }

    private func rasterize(glyph: CGGlyph, font: CTFont, key: GlyphKey) -> GlyphInfo? {
        var glyph = glyph
        var bbox = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
        if bbox.isNull || bbox.isEmpty {
            // A glyph with no ink (space): cache an empty rect, not nil, so
            // it is never looked up twice.
            let info = GlyphInfo(uvRect: .zero, size: .zero, bearing: .zero)
            cache[key] = info
            return info
        }
        // Round outward and pad by one texel so linear sampling never bleeds
        // in a neighbouring glyph.
        bbox = bbox.insetBy(dx: -1, dy: -1)
        let width = max(1, Int(bbox.width.rounded(.up)))
        let height = max(1, Int(bbox.height.rounded(.up)))
        guard let origin = allocate(width: width, height: height) else { return nil }

        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(false)  // no subpixel AA since Mojave
        context.setFillColor(gray: 1, alpha: 1)
        // A `CGContext`'s pixel buffer is always stored top-down in memory,
        // but its default drawing coordinate system is y-up with the origin
        // at the bottom-left. Flip the CTM so glyph-space "up" (towards the
        // cap height) matches buffer-space "up" (towards row 0) — otherwise
        // every glyph rasterises upside down relative to the atlas texture.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        var position = CGPoint(x: -bbox.minX, y: -bbox.minY)
        CTFontDrawGlyphs(font, &glyph, &position, 1, context)

        guard let data = context.data else { return nil }
        texture.replace(
            region: MTLRegionMake2D(origin.x, origin.y, width, height),
            mipmapLevel: 0, withBytes: data, bytesPerRow: width)

        let info = GlyphInfo(
            uvRect: SIMD4<Float>(
                Float(origin.x) / Float(Self.atlasSize), Float(origin.y) / Float(Self.atlasSize),
                Float(width) / Float(Self.atlasSize), Float(height) / Float(Self.atlasSize)),
            size: SIMD2<Float>(Float(width), Float(height)),
            bearing: SIMD2<Float>(Float(bbox.minX), Float(bbox.minY))
        )
        cache[key] = info
        return info
    }

    private func allocate(width: Int, height: Int) -> (x: Int, y: Int)? {
        if nextOrigin.x + width > Self.atlasSize {
            nextOrigin = (0, nextOrigin.y + rowHeight)
            rowHeight = 0
        }
        guard nextOrigin.y + height <= Self.atlasSize else { return nil }
        let origin = nextOrigin
        nextOrigin.x += width
        rowHeight = max(rowHeight, height)
        return origin
    }
}
