import CoreGraphics
import CoreText
import Metal
import simd

/// Rasterises glyphs into an `r8Unorm` texture atlas and caches them by
/// scalar, cluster and weight. Color glyphs (Apple Color Emoji bitmaps)
/// rasterise into a second, `bgra8Unorm` atlas instead — see below.
///
/// **ASCII fast path.** `glyph(forASCII:style:)` looks the glyph up directly
/// with `CTFontGetGlyphsForCharacters` — no `CTLine`, no shaping. Calling
/// into shaping per line per frame costs milliseconds and blows the frame
/// budget on its own (`PERFORMANCE.md` §2.2); ASCII is the overwhelming
/// majority of terminal content, so it must never pay that cost.
///
/// **Everything else** goes through a shaping cache (`PERFORMANCE.md` §2.2):
/// `glyph(shaping:style:)` for single scalars, `glyph(forCluster:style:)` for
/// the multi-scalar grapheme clusters the core's `GraphemeTable` hands out
/// (`DESIGN.md` §2.3). Each shapes via `CTLine` once per key and caches the
/// result — paid once, not per frame.
///
/// **Font fallback** (M3.5) is Core Text's cascade list: a `CTLine` shaped
/// with a font that lacks a scalar resolves the run to a fallback font, and
/// the *run's* font — not the requested one — is what rasterises the glyph.
/// (Rasterising a fallback glyph with the primary font drew the wrong
/// glyph's outlines: glyph ids are per-font.) The cascade is pinned by
/// `TerminalFont` (PingFang SC, then Apple Color Emoji) rather than left to
/// the system.
///
/// **Color glyphs.** `CTFontDrawGlyphs` rasterises outlines only — an emoji
/// shaped through to Apple Color Emoji comes out blank, so color runs
/// (detected by the font's `traitColorGlyphs`) are drawn with `CTRunDraw`
/// into an RGBA context and uploaded to `colorTexture` (`bgra8Unorm`,
/// premultiplied). The renderer draws those quads in a separate pass whose
/// fragment returns the texture sample directly instead of tinting coverage.
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
/// **Single-threaded.** The cache, the shelf allocator and the texture are
/// plain mutable state with no synchronisation, and Core Text's run and line
/// objects are not safe to share either — rasterising the same atlas from two
/// threads segfaults inside `CTRunGetImageBounds`. In the app that holds
/// naturally: the renderer is driven from the display link on the main
/// thread. Tests that build an atlas therefore have to be serialised.
nonisolated final class GlyphAtlas {
    /// The four faces a cell can ask for. A raw bitfield rather than two
    /// `Bool`s: it is the atlas's cache key and the renderer builds one per
    /// cell per frame straight out of `Cell.attributes.rawValue`, so it must
    /// cost two bit tests and no function calls (`PERFORMANCE.md` §3).
    struct Style: Hashable {
        var rawValue: UInt8

        init(rawValue: UInt8) { self.rawValue = rawValue }

        init(bold: Bool, italic: Bool) {
            rawValue = (bold ? 1 : 0) | (italic ? 2 : 0)
        }

        static let regular = Style(rawValue: 0)
        static let bold = Style(rawValue: 1)
        static let italic = Style(rawValue: 2)
        static let boldItalic = Style(rawValue: 3)
    }

    struct GlyphKey: Hashable {
        var scalar: UInt32
        var style: Style
    }

    /// A multi-scalar cluster (`GraphemeTable` contents) plus weight. Keying
    /// by the shaped contents — not the core's `GraphemeID` — keeps the atlas
    /// correct across grids and across `GraphemeTable` resets, which reuse
    /// ids.
    struct ClusterKey: Hashable {
        var scalars: [UInt32]
        var style: Style
    }

    struct GlyphInfo {
        /// Atlas UV rect: (x, y, width, height), normalised to [0, 1].
        var uvRect: SIMD4<Float>
        /// Bitmap size, in pixels.
        var size: SIMD2<Float>
        /// Offset from the pen origin to the bitmap's top-left, pixels.
        var bearing: SIMD2<Float>
        /// True when the bitmap lives in `colorTexture` (premultiplied bgra)
        /// rather than `texture` — color emoji. The renderer routes these to
        /// the color pipeline, which ignores the instance tint.
        var isColor: Bool = false
        /// True when no font in the cascade could draw the scalar at all —
        /// the shaper produced `.notdef` and nothing else. Distinct from an
        /// inkless glyph (a no-break space, a zero-width joiner), which is a
        /// correct empty result: a missing glyph must be *visible*, or a
        /// terminal that silently drops characters looks like it lost output.
        /// The renderer draws a hollow box for these.
        var isMissing: Bool = false
    }

    /// The one-texel border `rasterize` pads every bitmap with so linear
    /// sampling cannot bleed in a neighbouring glyph. Callers comparing a
    /// glyph's bitmap against the cell box have to subtract it from both
    /// axes, or every glyph looks a little too wide.
    static let bitmapPadding: Float = 1

    static let atlasSize = 2048

    let atlasPixelSize: Int
    private(set) var texture: MTLTexture
    /// The RGBA atlas color glyphs rasterise into (see the type comment).
    /// Premultiplied bgra, matching what `CTRunDraw` produces and what the
    /// color pipeline's blend state expects.
    private(set) var colorTexture: MTLTexture
    /// The four faces, indexed by `Style.rawValue`, and whether each had to
    /// have its weight faked because the family has no real bold face.
    private var fonts: [CTFont]
    private var isSyntheticBold: [Bool]
    private var cache: [GlyphKey: GlyphInfo] = [:]
    private var clusterCache: [ClusterKey: GlyphInfo] = [:]
    private var nextOrigin = (x: 0, y: 1)  // row 0 is reserved: see `solidWhiteUV`
    private var rowHeight = 1
    /// The color atlas packs its own shelves (no reserved row on this one).
    private var nextColorOrigin = (x: 0, y: 0)
    private var colorRowHeight = 0

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
        // Pinning here — not only at the font's creation site — makes the
        // atlas the single choke point: the cascade list then holds whatever
        // font a caller hands in, and `TerminalFont.bold` re-pins after the
        // trait copy that would otherwise drop it (see `TerminalFont`).
        let base = TerminalFont.pinningCascadeList(font, size: CTFontGetSize(font))
        (self.fonts, self.isSyntheticBold) = Self.faces(of: base)
        self.atlasPixelSize = atlasPixelSize

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: atlasPixelSize, height: atlasPixelSize, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .managed
        self.texture = device.makeTexture(descriptor: descriptor)!

        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: atlasPixelSize, height: atlasPixelSize, mipmapped: false)
        colorDescriptor.usage = [.shaderRead]
        colorDescriptor.storageMode = .managed
        self.colorTexture = device.makeTexture(descriptor: colorDescriptor)!

        var white: UInt8 = 255
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 1)
    }

    /// Re-points the atlas at a new font, reusing the texture.
    ///
    /// Runtime font sizing (cmd-=/cmd--) used to construct a whole new
    /// renderer per keystroke, which meant a fresh multi-megabyte atlas
    /// texture *and* fresh Metal pipeline states every time a key repeated.
    /// The font changes; the storage and the pipelines do not need to.
    func reset(font newFont: CTFont) {
        let base = TerminalFont.pinningCascadeList(newFont, size: CTFontGetSize(newFont))
        (fonts, isSyntheticBold) = Self.faces(of: base)
        cache.removeAll(keepingCapacity: true)
        clusterCache.removeAll(keepingCapacity: true)
        nextOrigin = (x: 0, y: 1)
        rowHeight = 1
        nextColorOrigin = (x: 0, y: 0)
        colorRowHeight = 0
        evictionCount += 1
        var white: UInt8 = 255
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 1)
    }

    /// The four styled faces of `base` and their synthetic-bold flags —
    /// `TerminalFont.variant` does the deriving and the synthesis decisions.
    private static func faces(of base: CTFont) -> ([CTFont], [Bool]) {
        var fonts: [CTFont] = []
        var synthetic: [Bool] = []
        for rawValue in UInt8(0)...UInt8(3) {
            let style = Style(rawValue: rawValue)
            let derived = TerminalFont.variant(
                of: base, bold: style.rawValue & 1 != 0, italic: style.rawValue & 2 != 0)
            fonts.append(derived.font)
            synthetic.append(derived.syntheticBold)
        }
        return (fonts, synthetic)
    }

    /// ASCII fast path — see the type comment.
    func glyph(forASCII scalar: UInt32, style: Style) -> GlyphInfo? {
        let key = GlyphKey(scalar: scalar, style: style)
        if let cached = cache[key] { return cached }
        var utf16 = [UniChar(scalar)]
        var glyphs: [CGGlyph] = [0]
        let f = fonts[Int(style.rawValue)]
        let mapped = CTFontGetGlyphsForCharacters(f, &utf16, &glyphs, 1)
        fastPathHits += 1
        guard mapped, glyphs[0] != 0 else {
            // Unmapped by the primary face. The fast path deliberately does
            // not shape, so there is no cascade here to find the scalar in —
            // it is genuinely undrawable at this point, and the answer is a
            // *missing* glyph rather than nil. Returning nil drew nothing at
            // all, which reads as the terminal having lost the output.
            // Cached so the lookup does not repeat every frame.
            let missing = GlyphInfo(uvRect: .zero, size: .zero, bearing: .zero, isMissing: true)
            cache[key] = missing
            return missing
        }
        let info = rasterize(
            [(glyphs: glyphs, positions: [CGPoint.zero], font: f, isColor: false, ctRun: nil, ctLine: nil)],
            style: style)
        cache[key] = info
        return info
    }

    /// Non-ASCII single-scalar path — shapes via `CTLine`, once per key.
    func glyph(shaping scalar: UInt32, style: Style) -> GlyphInfo? {
        let key = GlyphKey(scalar: scalar, style: style)
        if let cached = cache[key] { return cached }
        guard let scalarValue = Unicode.Scalar(scalar) else { return nil }
        shapingHits += 1
        let shaped = shape(String(Character(scalarValue)), style: style)
        var info = rasterize(shaped.runs, style: style)
        if shaped.runs.isEmpty, shaped.sawNotdef { info.isMissing = true }
        cache[key] = info
        return info
    }

    // Two-value convenience overloads: most callers — and every test written
    // before italics existed — only ever ask for regular or bold.
    func glyph(forASCII scalar: UInt32, bold: Bool) -> GlyphInfo? {
        glyph(forASCII: scalar, style: Style(bold: bold, italic: false))
    }

    func glyph(shaping scalar: UInt32, bold: Bool) -> GlyphInfo? {
        glyph(shaping: scalar, style: Style(bold: bold, italic: false))
    }

    func glyph(forCluster scalars: [UInt32], bold: Bool) -> GlyphInfo? {
        glyph(forCluster: scalars, style: Style(bold: bold, italic: false))
    }

    /// Grapheme-cluster path (M3.6): shapes the whole cluster as one string,
    /// so a ZWJ emoji sequence comes back as the single glyph run the emoji
    /// font defines for it and a combining-mark cluster is positioned by the
    /// shaper rather than stacked by hand.
    func glyph(forCluster scalars: [UInt32], style: Style) -> GlyphInfo? {
        let key = ClusterKey(scalars: scalars, style: style)
        if let cached = clusterCache[key] { return cached }
        var view = String.UnicodeScalarView()
        for scalar in scalars {
            guard let value = Unicode.Scalar(scalar) else { return nil }
            view.append(value)
        }
        guard !view.isEmpty else { return nil }
        shapingHits += 1
        let shaped = shape(String(view), style: style)
        var info = rasterize(shaped.runs, style: style)
        if shaped.runs.isEmpty, shaped.sawNotdef { info.isMissing = true }
        clusterCache[key] = info
        return info
    }

    /// One shaped run: the glyphs and positions resolved through the cascade
    /// list, the font the run actually shaped with, whether that font is a
    /// color (bitmap) font, and — for color runs — the `CTRun` itself, since
    /// color bitmaps only rasterise through run-level drawing.
    ///
    /// `ctLine` is held alongside `ctRun` and is not otherwise used. A
    /// `CTRun`'s glyph storage belongs to the line that produced it, and
    /// retaining the run does not keep that line alive: once `shape` returned
    /// and the line was released, `CTRunGetImageBounds` read freed memory and
    /// crashed inside Core Text — intermittently, as dangling reads do.
    private typealias ShapedRun = (
        glyphs: [CGGlyph], positions: [CGPoint], font: CTFont, isColor: Bool,
        ctRun: CTRun?, ctLine: CTLine?
    )

    /// One shaped string as a flat list of runs.
    /// The font is the run's own: when the requested font lacks the scalars,
    /// Core Text resolves the run through its cascade list and the run carries
    /// the fallback font (M3.5) — rasterising with anything else draws glyphs
    /// from the wrong font entirely.
    ///
    /// Glyph 0 (`.notdef`) is dropped: drawing it would ink a placeholder
    /// box, and zero-width format characters (ZWJ) can surface as glyph 0 in
    /// a run. A string that shapes to nothing yields no runs and rasterises
    /// as an empty, cached glyph.
    ///
    /// `sawNotdef` reports that the shaper *did* produce glyphs and every one
    /// of them was `.notdef` — the caller turns that into a visible
    /// placeholder rather than an invisible gap.
    private func shape(_ string: String, style: Style)
        -> (runs: [ShapedRun], sawNotdef: Bool)
    {
        let requested = fonts[Int(style.rawValue)]
        var sawNotdef = false
        let attributed = CFAttributedStringCreate(
            nil, string as CFString, [kCTFontAttributeName: requested] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        guard let glyphRuns = CTLineGetGlyphRuns(line) as? [CTRun] else { return ([], false) }
        var runs: [ShapedRun] = []
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
            // Color fonts (Apple Color Emoji) must rasterise through
            // `CTRunDraw` — `CTFontDrawGlyphs` draws outlines only, which
            // for a bitmap font is nothing at all.
            let isColor = CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs)
                || (CTFontCopyPostScriptName(runFont) as String).hasPrefix("AppleColorEmoji")
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            let kept = zip(glyphs, positions).filter { $0.0 != 0 }
            if kept.isEmpty, glyphs.contains(0) { sawNotdef = true }
            guard !kept.isEmpty else { continue }
            runs.append(
                (kept.map(\.0), kept.map(\.1), runFont, isColor,
                 isColor ? run : nil, isColor ? line : nil))
        }
        return (runs, sawNotdef)
    }

    /// Rasterises one shaped glyph run list into the atlas. An empty list —
    /// or one whose glyphs have no ink (a space) — yields a cached empty
    /// `GlyphInfo`, so a blank cell is never shaped twice.
    private func rasterize(_ runs: [ShapedRun], style: Style) -> GlyphInfo {
        if runs.contains(where: \.isColor) {
            return rasterizeColor(runs)
        }
        // A family with no real bold face: fake the weight by stroking the
        // outline as well as filling it, so `SGR 1` content still reads as
        // bold instead of silently rendering regular (`TerminalFont.variant`).
        // The stroke is centred on the outline, so half of it grows the ink —
        // a twentieth of an em at each side, which the cell box absorbs.
        let strokeWidth: CGFloat =
            isSyntheticBold[Int(style.rawValue)]
            ? CTFontGetSize(fonts[Int(style.rawValue)]) * 0.04
            : 0
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
        // in a neighbouring glyph — plus half the synthetic stroke, which
        // grows the ink outward on every side and would otherwise clip.
        let pad = CGFloat(Self.bitmapPadding) + strokeWidth / 2
        let bbox = bounds.insetBy(dx: -pad, dy: -pad)
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
        if strokeWidth > 0 {
            context.setStrokeColor(gray: 1, alpha: 1)
            context.setLineWidth(strokeWidth)
            context.setTextDrawingMode(.fillStroke)
        }
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

    /// The color half of `rasterize` (see the type comment): at least one
    /// run shaped to a color font, so the bitmap goes into `colorTexture`
    /// (premultiplied bgra) instead of the coverage atlas.
    ///
    /// Color runs draw with `CTRunDraw` — the only Core Text entry point
    /// that renders bitmap glyphs; `CTFontDrawGlyphs` is outlines only. The
    /// bounds come from `CTRunGetImageBounds`, which unlike
    /// `CTFontGetBoundingRectsForGlyphs` knows the bitmap's real extent.
    /// `CTRunDraw` places the run relative to the context's text position,
    /// so that is set to `-bbox.origin` rather than shifting positions by
    /// hand. A grayscale run sharing the cluster (rare, but a mixed cluster
    /// is possible) still draws by outline with a white fill.
    ///
    /// Premultiplication: the context's `premultipliedFirst` bitmap info is
    /// what Core Graphics supports drawing into, and the color pipeline's
    /// blend state (`sourceRGB = .one`) is premultiplied-over, so the texels
    /// upload verbatim — no un-premultiply pass, no precision loss.
    private func rasterizeColor(_ runs: [ShapedRun]) -> GlyphInfo {
        let empty = GlyphInfo(uvRect: .zero, size: .zero, bearing: .zero, isColor: true)
        var bounds = CGRect.null
        for run in runs {
            if let ctRun = run.ctRun {
                // location 0 / length 0 means the whole run.
                bounds = bounds.union(CTRunGetImageBounds(ctRun, nil, CFRange(location: 0, length: 0)))
            } else {
                var glyphs = run.glyphs
                var rects = [CGRect](repeating: .zero, count: glyphs.count)
                CTFontGetBoundingRectsForGlyphs(run.font, .horizontal, &glyphs, &rects, glyphs.count)
                for (rect, position) in zip(rects, run.positions) {
                    bounds = bounds.union(rect.offsetBy(dx: position.x, dy: position.y))
                }
            }
        }
        guard !bounds.isNull, !bounds.isEmpty else { return empty }
        let bbox = bounds.insetBy(dx: -CGFloat(Self.bitmapPadding), dy: -CGFloat(Self.bitmapPadding))
        let width = max(1, Int(bbox.width.rounded(.up)))
        let height = max(1, Int(bbox.height.rounded(.up)))
        var allocation = allocateColor(width: width, height: height)
        if allocation == nil {
            // The page is full: reset and retry once (see the type comment).
            evict()
            allocation = allocateColor(width: width, height: height)
        }
        guard let origin = allocation,
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return empty }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(false)  // no subpixel AA since Mojave
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        // No CTM flip, for the same reason as the grayscale path: top-down
        // buffer against y-up drawing coordinates cancels out.
        for run in runs {
            if let ctRun = run.ctRun {
                context.textPosition = CGPoint(x: -bbox.minX, y: -bbox.minY)
                CTRunDraw(ctRun, context, CFRange(location: 0, length: 0))
            } else {
                var glyphs = run.glyphs
                var positions = run.positions.map {
                    CGPoint(x: $0.x - bbox.minX, y: $0.y - bbox.minY)
                }
                CTFontDrawGlyphs(run.font, &glyphs, &positions, glyphs.count, context)
            }
        }

        guard let data = context.data else { return empty }
        colorTexture.replace(
            region: MTLRegionMake2D(origin.x, origin.y, width, height),
            mipmapLevel: 0, withBytes: data, bytesPerRow: width * 4)

        return GlyphInfo(
            uvRect: SIMD4<Float>(
                Float(origin.x) / Float(atlasPixelSize), Float(origin.y) / Float(atlasPixelSize),
                Float(width) / Float(atlasPixelSize), Float(height) / Float(atlasPixelSize)),
            size: SIMD2<Float>(Float(width), Float(height)),
            bearing: SIMD2<Float>(Float(bbox.minX), Float(bbox.minY)),
            isColor: true
        )
    }

    /// Full-atlas reset on exhaustion — see the type comment. The textures
    /// themselves are kept: the allocators rewind to their origins and every
    /// lookup is a cache miss that re-rasterises into freshly allocated (and
    /// thus freshly written) regions, so stale texels are never sampled. The
    /// reserved white texel at (0, 0) sits below the grayscale allocator's
    /// first row and survives. Both allocators rewind together: an eviction
    /// clears both caches, so a kept color shelf would only ever be
    /// re-allocated over.
    private func evict() {
        cache.removeAll(keepingCapacity: true)
        clusterCache.removeAll(keepingCapacity: true)
        nextOrigin = (x: 0, y: 1)
        rowHeight = 1
        nextColorOrigin = (x: 0, y: 0)
        colorRowHeight = 0
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

    /// The color atlas's shelf packer — the same scheme as `allocate`, over
    /// its own state, starting at row 0 (no reserved texel on this page).
    private func allocateColor(width: Int, height: Int) -> (x: Int, y: Int)? {
        if nextColorOrigin.x + width > atlasPixelSize {
            nextColorOrigin = (0, nextColorOrigin.y + colorRowHeight)
            colorRowHeight = 0
        }
        guard nextColorOrigin.y + height <= atlasPixelSize else { return nil }
        let origin = nextColorOrigin
        nextColorOrigin.x += width
        colorRowHeight = max(colorRowHeight, height)
        return origin
    }
}
