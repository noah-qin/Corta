import CoreGraphics
import CoreText
import Metal
import simd

/// Rasterises glyphs into an `r8Unorm` texture atlas and caches them by
/// scalar, cluster and weight.
///
/// **ASCII fast path.** `glyph(forASCII:bold:)` looks the glyph up directly
/// with `CTFontGetGlyphsForCharacters` — no `CTLine`, no shaping. Calling
/// into shaping per line per frame costs milliseconds and blows the frame
/// budget on its own (`PERFORMANCE.md` §2.2); ASCII is the overwhelming
/// majority of terminal content, so it must never pay that cost.
///
/// **Everything else** goes through a shaping cache (`PERFORMANCE.md` §2.2):
/// `glyph(shaping:bold:)` for single scalars, `glyph(forCluster:bold:)` for
/// the multi-scalar grapheme clusters the core's `GraphemeTable` hands out
/// (`DESIGN.md` §2.3). Each shapes via `CTLine` once per key and caches the
/// result — paid once, not per frame.
///
/// **Font fallback** (M3.5) is Core Text's cascade list: a `CTLine` shaped
/// with a font that lacks a scalar resolves the run to a fallback font, and
/// the *run's* font — not the requested one — is what rasterises the glyph.
/// (Rasterising a fallback glyph with the primary font drew the wrong
/// glyph's outlines: glyph ids are per-font.)
///
/// **Eviction** (M3, `DESIGN.md` §7 hard part 4): a CJK session exhausts a
/// single 2048×2048 page, and shelf packing cannot reclaim individual slots
/// without fragmenting, so on exhaustion the whole atlas is reset — every
/// cache cleared, the allocator rewound — and glyphs re-rasterise on demand
/// (the strategy Alacritty uses for the same reason). Every `GlyphInfo`
/// handed out before a reset holds stale UVs, so `generation` counts resets
/// and the renderer rebuilds all rows when it changes mid-frame. A screen
/// whose live content alone exceeds the atlas cannot be served by any
/// eviction policy; after one retry those cells draw blank.
nonisolated final class GlyphAtlas {
    struct GlyphKey: Hashable {
        var scalar: UInt32
        var bold: Bool
    }

    /// A multi-scalar cluster (`GraphemeTable` contents) plus weight. Keying
    /// by the shaped contents — not the core's `GraphemeID` — keeps the atlas
    /// correct across grids and across `GraphemeTable` resets, which reuse
    /// ids.
    struct ClusterKey: Hashable {
        var scalars: [UInt32]
        var bold: Bool
    }

    struct GlyphInfo {
        /// Atlas UV rect: (x, y, width, height), normalised to [0, 1].
        var uvRect: SIMD4<Float>
        /// Bitmap size, in pixels.
        var size: SIMD2<Float>
        /// Offset from the pen origin to the bitmap's top-left, pixels.
        var bearing: SIMD2<Float>
    }

    static let atlasSize = 2048

    let atlasPixelSize: Int
    private(set) var texture: MTLTexture
    private let font: CTFont
    private let boldFont: CTFont
    private var cache: [GlyphKey: GlyphInfo] = [:]
    private var clusterCache: [ClusterKey: GlyphInfo] = [:]
    private var nextOrigin = (x: 0, y: 1)  // row 0 is reserved: see `solidWhiteUV`
    private var rowHeight = 1

    /// Counters for tests: prove the ASCII path never shapes, and that
    /// fallback and eviction happen when they should.
    private(set) var fastPathHits = 0
    private(set) var shapingHits = 0
    /// How many shaped runs resolved to a font other than the requested one —
    /// Core Text's cascade list at work (M3.5).
    private(set) var fallbackHits = 0
    /// How many times a full atlas was reset (see the type comment).
    private(set) var evictionCount = 0
    /// Bumped on every eviction reset. UVs issued before a bump are stale.
    private(set) var generation = 0

    /// A 1×1 fully-opaque texel at the atlas origin, sampled by cursor and
    /// selection quads so they can share the glyph pipeline instead of a
    /// third one.
    static let solidWhiteUV = SIMD4<Float>(0, 0, 0, 0)

    /// - Parameter atlasPixelSize: edge length of the square atlas texture.
    ///   Tests pass a small size to exercise eviction without rasterising
    ///   thousands of glyphs.
    init(device: MTLDevice, font: CTFont, atlasPixelSize: Int = GlyphAtlas.atlasSize) {
        self.font = font
        self.boldFont = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitBold, .traitBold) ?? font
        self.atlasPixelSize = atlasPixelSize

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: atlasPixelSize, height: atlasPixelSize, mipmapped: false)
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
        let info = rasterize([(glyphs: glyphs, positions: [CGPoint.zero], font: f)])
        cache[key] = info
        return info
    }

    /// Non-ASCII single-scalar path — shapes via `CTLine`, once per key.
    func glyph(shaping scalar: UInt32, bold: Bool) -> GlyphInfo? {
        let key = GlyphKey(scalar: scalar, bold: bold)
        if let cached = cache[key] { return cached }
        guard let scalarValue = Unicode.Scalar(scalar) else { return nil }
        shapingHits += 1
        let info = rasterize(shape(String(Character(scalarValue)), bold: bold))
        cache[key] = info
        return info
    }

    /// Grapheme-cluster path (M3.6): shapes the whole cluster as one string,
    /// so a ZWJ emoji sequence comes back as the single glyph run the emoji
    /// font defines for it and a combining-mark cluster is positioned by the
    /// shaper rather than stacked by hand.
    func glyph(forCluster scalars: [UInt32], bold: Bool) -> GlyphInfo? {
        let key = ClusterKey(scalars: scalars, bold: bold)
        if let cached = clusterCache[key] { return cached }
        var view = String.UnicodeScalarView()
        for scalar in scalars {
            guard let value = Unicode.Scalar(scalar) else { return nil }
            view.append(value)
        }
        guard !view.isEmpty else { return nil }
        shapingHits += 1
        let info = rasterize(shape(String(view), bold: bold))
        clusterCache[key] = info
        return info
    }

    /// One shaped string as a flat list of (glyphs, positions, font) runs.
    /// The font is the run's own: when the requested font lacks the scalars,
    /// Core Text resolves the run through its cascade list and the run carries
    /// the fallback font (M3.5) — rasterising with anything else draws glyphs
    /// from the wrong font entirely.
    ///
    /// Glyph 0 (`.notdef`) is dropped: drawing it would ink a placeholder
    /// box, and zero-width format characters (ZWJ) can surface as glyph 0 in
    /// a run. A string that shapes to nothing yields no runs and rasterises
    /// as an empty, cached glyph.
    private func shape(_ string: String, bold: Bool) -> [(glyphs: [CGGlyph], positions: [CGPoint], font: CTFont)] {
        let requested = bold ? boldFont : font
        let attributed = CFAttributedStringCreate(
            nil, string as CFString, [kCTFontAttributeName: requested] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        guard let glyphRuns = CTLineGetGlyphRuns(line) as? [CTRun] else { return [] }
        var runs: [(glyphs: [CGGlyph], positions: [CGPoint], font: CTFont)] = []
        for run in glyphRuns {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as? [CFString: Any]
            let runFont: CTFont
            if let value = attributes?[kCTFontAttributeName] {
                // A run's font attribute is always a CTFont; the conditional
                // is only about the key's presence.
                runFont = value as! CTFont
            } else {
                runFont = requested
            }
            if !CFEqual(runFont, requested) { fallbackHits += 1 }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            let kept = zip(glyphs, positions).filter { $0.0 != 0 }
            guard !kept.isEmpty else { continue }
            runs.append((kept.map(\.0), kept.map(\.1), runFont))
        }
        return runs
    }

    /// Rasterises one shaped glyph run list into the atlas. An empty list —
    /// or one whose glyphs have no ink (a space) — yields a cached empty
    /// `GlyphInfo`, so a blank cell is never shaped twice.
    private func rasterize(
        _ runs: [(glyphs: [CGGlyph], positions: [CGPoint], font: CTFont)]
    ) -> GlyphInfo {
        // The union of every run's bounding boxes, positions applied: a
        // cluster's glyphs do not share an origin.
        var bounds = CGRect.null
        for run in runs {
            var glyphs = run.glyphs
            var rects = [CGRect](repeating: .zero, count: glyphs.count)
            CTFontGetBoundingRectsForGlyphs(run.font, .horizontal, &glyphs, &rects, glyphs.count)
            for (rect, position) in zip(rects, run.positions) {
                bounds = bounds.union(rect.offsetBy(dx: position.x, dy: position.y))
            }
        }
        guard !bounds.isNull, !bounds.isEmpty else {
            return GlyphInfo(uvRect: .zero, size: .zero, bearing: .zero)
        }
        // Round outward and pad by one texel so linear sampling never bleeds
        // in a neighbouring glyph.
        let bbox = bounds.insetBy(dx: -1, dy: -1)
        let width = max(1, Int(bbox.width.rounded(.up)))
        let height = max(1, Int(bbox.height.rounded(.up)))
        var allocation = allocate(width: width, height: height)
        if allocation == nil {
            // The page is full: reset and retry once (see the type comment).
            evict()
            allocation = allocate(width: width, height: height)
        }
        guard let origin = allocation,
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return GlyphInfo(uvRect: .zero, size: .zero, bearing: .zero) }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(false)  // no subpixel AA since Mojave
        context.setFillColor(gray: 1, alpha: 1)
        // No CTM flip. A `CGContext`'s pixel buffer is stored top-down in
        // memory while its drawing coordinates are y-up from the bottom-left,
        // and those two cancel: a glyph drawn normally lands with its cap
        // height in row 0. The shader then maps quad corner (0,0) — the
        // quad's top-left, since pixel space is y-down — straight onto the
        // atlas region's top row, so no flip belongs anywhere in this path.
        // Flipping the CTM here rasterised every glyph upside down.
        for run in runs {
            var glyphs = run.glyphs
            var positions = run.positions.map {
                CGPoint(x: $0.x - bbox.minX, y: $0.y - bbox.minY)
            }
            CTFontDrawGlyphs(run.font, &glyphs, &positions, glyphs.count, context)
        }

        guard let data = context.data else {
            return GlyphInfo(uvRect: .zero, size: .zero, bearing: .zero)
        }
        texture.replace(
            region: MTLRegionMake2D(origin.x, origin.y, width, height),
            mipmapLevel: 0, withBytes: data, bytesPerRow: width)

        return GlyphInfo(
            uvRect: SIMD4<Float>(
                Float(origin.x) / Float(atlasPixelSize), Float(origin.y) / Float(atlasPixelSize),
                Float(width) / Float(atlasPixelSize), Float(height) / Float(atlasPixelSize)),
            size: SIMD2<Float>(Float(width), Float(height)),
            bearing: SIMD2<Float>(Float(bbox.minX), Float(bbox.minY))
        )
    }

    /// Full-atlas reset on exhaustion — see the type comment. The texture
    /// itself is kept: the allocator rewinds to the origin and every lookup
    /// is a cache miss that re-rasterises into freshly allocated (and thus
    /// freshly written) regions, so stale texels are never sampled. The
    /// reserved white texel at (0, 0) sits below the allocator's first row
    /// and survives.
    private func evict() {
        cache.removeAll(keepingCapacity: true)
        clusterCache.removeAll(keepingCapacity: true)
        nextOrigin = (x: 0, y: 1)
        rowHeight = 1
        evictionCount += 1
        generation += 1
    }

    private func allocate(width: Int, height: Int) -> (x: Int, y: Int)? {
        if nextOrigin.x + width > atlasPixelSize {
            nextOrigin = (0, nextOrigin.y + rowHeight)
            rowHeight = 0
        }
        guard nextOrigin.y + height <= atlasPixelSize else { return nil }
        let origin = nextOrigin
        nextOrigin.x += width
        rowHeight = max(rowHeight, height)
        return origin
    }
}
