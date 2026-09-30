// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import CoreText
import Metal
import simd

/// Rasterises glyphs into an `r8Unorm` atlas, cached by scalar, cluster
/// and weight; color glyphs go to a second, `bgra8Unorm` atlas.
///
/// **ASCII fast path.** `glyph(forASCII:style:)` maps via
/// `CTFontGetGlyphsForCharacters` with no shaping: per-frame shaping blows
/// the frame budget (`PERFORMANCE.md` §2.2), and ASCII is most of the
/// screen. Everything else shapes through `CTLine` once per key and caches
/// the result.
///
/// **Font fallback** is Core Text's cascade list (pinned by `TerminalFont`),
/// and the *run's* font rasterises the glyph: glyph ids are per-font.
///
/// **Color glyphs.** `CTFontDrawGlyphs` draws outlines only, so runs in a
/// `traitColorGlyphs` font are drawn with `CTRunDraw` into `colorTexture`
/// (premultiplied bgra), which a separate pass samples untinted.
///
/// **Pages.** The grayscale texture holds `asciiPage` (plus the reserved
/// white texel row) and `shapedPage`; the color texture holds `colorPage`.
/// Each page has its own shelf allocator and cache, so a CJK- or
/// emoji-heavy screen filling one page never evicts another.
///
/// **Eviction is per page; `generation` is global** (`DESIGN.md` §7.4). A
/// full page resets itself and glyphs re-rasterise on demand. Any page's
/// eviction bumps `generation`, because a row mid-build may hold a UV
/// from it, and the renderer's one-retry rebuild
/// (`TerminalRenderer.updateInstances`) must catch that. Content larger
/// than a page draws blank after the retry.
///
/// **Allocation failure.** `init` halves the size down to
/// `minimumAtlasPixelSize` and sets `isDegraded`; only failing at the
/// minimum traps, since such a device can render nothing.
///
/// **Single-threaded.** No synchronisation, and Core Text objects are not
/// shareable — two threads segfault in `CTRunGetImageBounds`. The app
/// drives it from the main thread; tests that build one are serialised.
nonisolated final class GlyphAtlas {
    /// The four faces, as two bits: part of the glyph-cache key looked up
    /// per cell per frame.
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

    /// A multi-scalar cluster plus weight, keyed by contents rather than
    /// `GraphemeID`, which is reused across grids and table resets.
    struct ClusterKey: Hashable {
        var scalars: [UInt32]
        var style: Style
    }

    struct GlyphInfo {
        /// Atlas UV rect: (x, y, width, height), normalised to [0, 1].
        var uvRect: SIMD4<Float>
        /// Bitmap size, in pixels.
        var size: SIMD2<Float>
        /// From the pen origin to the bitmap's top-left, in pixels.
        var bearing: SIMD2<Float>
        /// The bitmap is in `colorTexture`; drawn untinted.
        var isColor: Bool = false
        /// No font in the cascade has the scalar (only `.notdef`). Unlike an
        /// inkless glyph such as ZWJ, it draws as a hollow box so dropped
        /// characters stay visible.
        var isMissing: Bool = false
    }

    /// One independently packed and evicted region: a shelf packer over a
    /// fixed rectangle plus its glyph and cluster caches.
    private final class AtlasPage {
        let regionOrigin: (x: Int, y: Int)
        let regionSize: (width: Int, height: Int)
        var cache: [GlyphKey: GlyphInfo] = [:]
        var clusterCache: [ClusterKey: GlyphInfo] = [:]
        /// The ASCII page's cache, indexed by `(style << 7) | scalar`: the
        /// per-cell lookup is an index, not a hash. Empty on other pages.
        var asciiTable: ContiguousArray<GlyphInfo?>
        private var nextOrigin: (x: Int, y: Int)
        private var rowHeight: Int

        /// - Parameter reservedFirstRow: skip the first row, which holds
        ///   `GlyphAtlas.solidWhiteUV` (for `asciiPage`).
        init(regionOrigin: (x: Int, y: Int), regionSize: (width: Int, height: Int), reservedFirstRow: Bool) {
            self.regionOrigin = regionOrigin
            self.regionSize = regionSize
            self.asciiTable = reservedFirstRow ? ContiguousArray(repeating: nil, count: 4 << 7) : []
            self.nextOrigin = reservedFirstRow ? (regionOrigin.x, regionOrigin.y + 1) : regionOrigin
            self.rowHeight = reservedFirstRow ? 1 : 0
        }

        func allocate(width: Int, height: Int) -> (x: Int, y: Int)? {
            if nextOrigin.x + width > regionOrigin.x + regionSize.width {
                nextOrigin = (regionOrigin.x, nextOrigin.y + rowHeight)
                rowHeight = 0
            }
            guard nextOrigin.y + height <= regionOrigin.y + regionSize.height else { return nil }
            let origin = nextOrigin
            nextOrigin.x += width
            rowHeight = max(rowHeight, height)
            return origin
        }

        /// Resets this page only.
        func evict(reservedFirstRow: Bool) {
            cache.removeAll(keepingCapacity: true)
            clusterCache.removeAll(keepingCapacity: true)
            for index in asciiTable.indices { asciiTable[index] = nil }
            nextOrigin = reservedFirstRow ? (regionOrigin.x, regionOrigin.y + 1) : regionOrigin
            rowHeight = reservedFirstRow ? 1 : 0
        }
    }

    /// The one-texel border against sampling bleed. Subtract it on both axes
    /// when comparing a bitmap to the cell box.
    static let bitmapPadding: Float = 1

    static let atlasSize = 2048

    /// The smallest edge `init` falls back to; still dozens of glyphs.
    static let minimumAtlasPixelSize = 64

    /// The edge actually allocated, after any fallback.
    private(set) var atlasPixelSize: Int
    /// Allocation fell back to a smaller size; capacity is reduced.
    private(set) var isDegraded = false
    private(set) var texture: MTLTexture
    /// Premultiplied bgra, as `CTRunDraw` produces and the color pipeline
    /// blends.
    private(set) var colorTexture: MTLTexture
    /// Indexed by `Style.rawValue`, with whether each bold is synthetic.
    private var fonts: [CTFont]
    private var isSyntheticBold: [Bool]
    /// The two-cell box a color glyph is rasterised to fit, in pixels.
    private var colorBox: CGSize

    /// Top half of the grayscale texture.
    private var asciiPage: AtlasPage
    /// Bottom half of the grayscale texture.
    private var shapedPage: AtlasPage
    /// The whole color texture.
    private var colorPage: AtlasPage

    /// Test counters: the ASCII path never shapes; fallback and eviction fire.
    private(set) var fastPathHits = 0
    private(set) var shapingHits = 0
    private(set) var fallbackHits = 0
    /// Page resets, across all pages.
    private(set) var evictionCount = 0
    /// Bumped on any page's eviction; earlier UVs may be stale.
    private(set) var generation = 0

    /// An opaque texel at the origin, so cursor and selection quads share the
    /// glyph pipeline. Reserved in `asciiPage`, never evicted.
    static let solidWhiteUV = SIMD4<Float>(0, 0, 0, 0)

    /// - Parameter atlasPixelSize: the square atlas edge; tests pass a small
    ///   one to exercise eviction.
    /// - Parameter makeTexture: a test hook to fail allocations; nil uses the
    ///   device.
    init(
        device: MTLDevice, font: CTFont, atlasPixelSize: Int = GlyphAtlas.atlasSize,
        makeTexture: ((MTLTextureDescriptor) -> MTLTexture?)? = nil
    ) {
        // Pinned here too, so the atlas is the one choke point for the cascade.
        let base = TerminalFont.pinningCascadeList(font, size: CTFontGetSize(font))
        (self.fonts, self.isSyntheticBold) = Self.faces(of: base)
        self.colorBox = Self.colorBox(for: base)

        let allocate = makeTexture ?? { device.makeTexture(descriptor: $0) }
        // Halve and retry down to `minimumAtlasPixelSize`; the trap below it is
        // deliberate.
        var size = max(1, atlasPixelSize)
        var allocated: (gray: MTLTexture, color: MTLTexture)?
        while true {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm, width: size, height: size, mipmapped: false)
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .managed
            let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
            colorDescriptor.usage = [.shaderRead]
            colorDescriptor.storageMode = .managed
            if let gray = allocate(descriptor), let color = allocate(colorDescriptor) {
                allocated = (gray, color)
                break
            }
            guard size > Self.minimumAtlasPixelSize else { break }
            size = max(size / 2, Self.minimumAtlasPixelSize)
        }
        guard let allocated else {
            preconditionFailure(
                "Metal device could not allocate even a \(Self.minimumAtlasPixelSize)-pixel glyph atlas")
        }
        self.texture = allocated.gray
        self.colorTexture = allocated.color
        self.atlasPixelSize = size
        self.isDegraded = size < atlasPixelSize

        (self.asciiPage, self.shapedPage, self.colorPage) = Self.makePages(atlasPixelSize: size)

        var white: UInt8 = 255
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 1)
    }

    /// Two cells of `font`, which is already in pixels: the renderer's box
    /// for a wide glyph, so an emoji drawn to fit it is never scaled on the
    /// GPU.
    private static func colorBox(for font: CTFont) -> CGSize {
        let metrics = CellMetrics(font: font)
        return CGSize(width: metrics.cellWidth * 2, height: metrics.cellHeight)
    }

    /// The three pages' fixed regions, fresh each call so `init` and `reset`
    /// never rewind them by hand.
    private static func makePages(atlasPixelSize: Int) -> (ascii: AtlasPage, shaped: AtlasPage, color: AtlasPage) {
        let half = atlasPixelSize / 2
        let ascii = AtlasPage(
            regionOrigin: (0, 0), regionSize: (atlasPixelSize, half), reservedFirstRow: true)
        let shaped = AtlasPage(
            regionOrigin: (0, half), regionSize: (atlasPixelSize, atlasPixelSize - half),
            reservedFirstRow: false)
        let color = AtlasPage(
            regionOrigin: (0, 0), regionSize: (atlasPixelSize, atlasPixelSize), reservedFirstRow: false)
        return (ascii, shaped, color)
    }

    /// Re-points the atlas at a new font, keeping the texture and pipelines:
    /// ⌘= / ⌘- call this per key repeat.
    func reset(font newFont: CTFont) {
        let base = TerminalFont.pinningCascadeList(newFont, size: CTFontGetSize(newFont))
        (fonts, isSyntheticBold) = Self.faces(of: base)
        colorBox = Self.colorBox(for: base)
        (asciiPage, shapedPage, colorPage) = Self.makePages(atlasPixelSize: atlasPixelSize)
        evictionCount += 1
        generation += 1
        var white: UInt8 = 255
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 1)
    }

    /// The four faces of `base` and their synthetic-bold flags
    /// (`TerminalFont.variant`).
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

    /// ASCII fast path — see the type comment. The renderer passes only
    /// ASCII, looked up by index; anything else keeps a dictionary entry.
    func glyph(forASCII scalar: UInt32, style: Style) -> GlyphInfo? {
        let index = scalar < 0x80 ? Int(style.rawValue) << 7 | Int(scalar) : nil
        if let index {
            if let cached = asciiPage.asciiTable[index] { return cached }
        } else if let cached = asciiPage.cache[GlyphKey(scalar: scalar, style: style)] {
            return cached
        }
        var utf16 = [UniChar(scalar)]
        var glyphs: [CGGlyph] = [0]
        let f = fonts[Int(style.rawValue)]
        let mapped = CTFontGetGlyphsForCharacters(f, &utf16, &glyphs, 1)
        fastPathHits += 1
        guard mapped, glyphs[0] != 0 else {
            // Unmapped by the primary face, and the fast path has no cascade:
            // cache a missing glyph, never nil, which would draw nothing.
            let missing = GlyphInfo(uvRect: .zero, size: .zero, bearing: .zero, isMissing: true)
            store(missing, forASCII: scalar, style: style, at: index)
            return missing
        }
        let info = rasterize(
            [(glyphs: glyphs, positions: [CGPoint.zero], font: f, isColor: false, ctRun: nil, ctLine: nil)],
            style: style, page: asciiPage)
        store(info, forASCII: scalar, style: style, at: index)
        return info
    }

    private func store(_ info: GlyphInfo, forASCII scalar: UInt32, style: Style, at index: Int?) {
        if let index {
            asciiPage.asciiTable[index] = info
        } else {
            asciiPage.cache[GlyphKey(scalar: scalar, style: style)] = info
        }
    }

    /// Non-ASCII single scalars, shaped once per key.
    func glyph(shaping scalar: UInt32, style: Style) -> GlyphInfo? {
        let key = GlyphKey(scalar: scalar, style: style)
        if let cached = shapedPage.cache[key] { return cached }
        guard let scalarValue = Unicode.Scalar(scalar) else { return nil }
        shapingHits += 1
        let shaped = shape(String(Character(scalarValue)), style: style)
        var info = rasterize(shaped.runs, style: style, page: shapedPage)
        if shaped.runs.isEmpty, shaped.sawNotdef { info.isMissing = true }
        shapedPage.cache[key] = info
        return info
    }

    /// Shapes the whole cluster as one string, so ZWJ sequences and combining
    /// marks come out as the font defines them.
    func glyph(forCluster scalars: [UInt32], style: Style) -> GlyphInfo? {
        let key = ClusterKey(scalars: scalars, style: style)
        if let cached = shapedPage.clusterCache[key] { return cached }
        var view = String.UnicodeScalarView()
        for scalar in scalars {
            guard let value = Unicode.Scalar(scalar) else { return nil }
            view.append(value)
        }
        guard !view.isEmpty else { return nil }
        shapingHits += 1
        let shaped = shape(String(view), style: style)
        var info = rasterize(shaped.runs, style: style, page: shapedPage)
        if shaped.runs.isEmpty, shaped.sawNotdef { info.isMissing = true }
        shapedPage.clusterCache[key] = info
        return info
    }

    /// One shaped run and the font it actually used; `ctRun` for color runs.
    ///
    /// `ctLine` is held only to keep `ctRun` valid: a run's glyph storage
    /// belongs to its line, and once the line was freed
    /// `CTRunGetImageBounds` crashed intermittently.
    private typealias ShapedRun = (
        glyphs: [CGGlyph], positions: [CGPoint], font: CTFont, isColor: Bool,
        ctRun: CTRun?, ctLine: CTLine?
    )

    /// One shaped string as a flat list of runs, each with the font Core Text
    /// resolved (possibly a fallback).
    ///
    /// `.notdef` glyphs are dropped (ZWJ can surface as one); `sawNotdef`
    /// reports that every glyph was `.notdef`, so the caller draws a
    /// placeholder.
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
                runFont = value as! CTFont
            } else {
                runFont = requested
            }
            if !CFEqual(runFont, requested) { fallbackHits += 1 }
            // Bitmap fonts draw nothing through `CTFontDrawGlyphs`.
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

    /// Rasterises runs into `page`, caching inkless results too. A color run
    /// goes to `colorPage` instead (`rasterizeColor`).
    private func rasterize(_ runs: [ShapedRun], style: Style, page: AtlasPage) -> GlyphInfo {
        if runs.contains(where: \.isColor) {
            return rasterizeColor(runs)
        }
        // No real bold face: stroke as well as fill, a twentieth of an em at
        // each side, so `SGR 1` still reads bold (`TerminalFont.variant`).
        let strokeWidth: CGFloat =
            isSyntheticBold[Int(style.rawValue)]
            ? CTFontGetSize(fonts[Int(style.rawValue)]) * 0.04
            : 0
        // A cluster's glyphs don't share an origin.
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
        // Pad by a texel against bleed, plus half the synthetic stroke.
        let pad = CGFloat(Self.bitmapPadding) + strokeWidth / 2
        let bbox = bounds.insetBy(dx: -pad, dy: -pad)
        let width = max(1, Int(bbox.width.rounded(.up)))
        let height = max(1, Int(bbox.height.rounded(.up)))
        var allocation = page.allocate(width: width, height: height)
        if allocation == nil {
            // Full: reset this page and retry once.
            evict(page)
            allocation = page.allocate(width: width, height: height)
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
        // No CTM flip: the context's top-down buffer and y-up coordinates cancel,
        // and the shader maps quad (0,0) to the region's top row. A flip drew
        // every glyph upside down.
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

    /// The color half of `rasterize`, into `colorPage`.
    ///
    /// `CTRunDraw` is the only Core Text call that draws bitmaps, and
    /// `CTRunGetImageBounds` knows their real extent; the text position is set
    /// to `-bbox.origin`. The glyph is drawn scaled so its image, padding
    /// included, fits `colorBox` exactly, and the renderer draws the bitmap
    /// texel for texel. Drawn at the text size and scaled on the GPU instead,
    /// a bitmap emoji came out smaller than its two cells and soft. For a
    /// bitmap emoji the image bounds are the whole design square, so a small
    /// design (🔸) keeps its size against a large one (🔶). Scaling the
    /// context lets Core Text pick the strike for the size drawn. A grayscale run in a mixed cluster draws by outline
    /// in white. Texels upload premultiplied, matching the color pipeline's
    /// blend (`sourceRGB = .one`).
    private func rasterizeColor(_ runs: [ShapedRun]) -> GlyphInfo {
        let empty = GlyphInfo(uvRect: .zero, size: .zero, bearing: .zero, isColor: true)
        var bounds = CGRect.null
        for run in runs {
            if let ctRun = run.ctRun {
                // Length 0 means the whole run.
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
        let pad = CGFloat(Self.bitmapPadding)
        let fill = min(
            (colorBox.width - 2 * pad) / bounds.width,
            (colorBox.height - 2 * pad) / bounds.height)
        let scaled = CGRect(
            x: bounds.minX * fill, y: bounds.minY * fill,
            width: bounds.width * fill, height: bounds.height * fill)
        let bbox = scaled.insetBy(dx: -pad, dy: -pad)
        let width = max(1, Int(bbox.width.rounded(.up)))
        let height = max(1, Int(bbox.height.rounded(.up)))
        var allocation = colorPage.allocate(width: width, height: height)
        if allocation == nil {
            // Full: reset this page and retry once.
            evict(colorPage)
            allocation = colorPage.allocate(width: width, height: height)
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
        // No CTM flip, as in the grayscale path. Positions are in the
        // unscaled space the scale maps onto the bitmap.
        context.scaleBy(x: fill, y: fill)
        let offset = CGPoint(x: bbox.minX / fill, y: bbox.minY / fill)
        for run in runs {
            if let ctRun = run.ctRun {
                context.textPosition = CGPoint(x: -offset.x, y: -offset.y)
                CTRunDraw(ctRun, context, CFRange(location: 0, length: 0))
            } else {
                var glyphs = run.glyphs
                var positions = run.positions.map {
                    CGPoint(x: $0.x - offset.x, y: $0.y - offset.y)
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

    /// Resets one page in place: its allocator rewinds and its caches clear,
    /// so every lookup re-rasterises into rewritten texels.
    private func evict(_ page: AtlasPage) {
        page.evict(reservedFirstRow: page === asciiPage)
        evictionCount += 1
        generation += 1
    }
}
