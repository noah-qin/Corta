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

import AppKit
import CortaTerminal
import CoreGraphics
import CoreText
import Metal
import Synchronization
import simd

/// The device could not allocate the atlas's textures even at the smallest
/// size: GPU memory is exhausted, or the device is gone.
nonisolated enum GlyphAtlasError: Error, CustomStringConvertible {
    case textureUnavailable(minimumPixelSize: Int)

    var description: String {
        switch self {
        case .textureUnavailable(let size):
            "the GPU could not allocate a \(size)-pixel glyph atlas"
        }
    }
}

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
/// `minimumAtlasPixelSize` and sets `isDegraded`; failing at the minimum
/// throws `GlyphAtlasError`, and the pane shows its renderer failure.
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
        // periphery:ignore - read by the synthesised hash and ==
        var scalar: UInt32
        // periphery:ignore - read by the synthesised hash and ==
        var style: Style
    }

    /// A multi-scalar cluster plus weight, keyed by contents rather than
    /// `GraphemeID`, which is reused across grids and table resets.
    struct ClusterKey: Hashable {
        // periphery:ignore - read by the synthesised hash and ==
        var scalars: [UInt32]
        // periphery:ignore - read by the synthesised hash and ==
        var style: Style
    }

    struct GlyphInfo {
        /// Diagnostic UV rect normalised to the virtual ceiling. Rendering
        /// uses atlasIndex and integer pixel rectangles, not these UVs.
        var uvRect: SIMD4<Float>
        var atlasIndex: UInt32 = 0
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
    final class AtlasPage {
        let regionOrigin: (x: Int, y: Int)
        let regionSize: (width: Int, height: Int)
        var cache: [GlyphKey: GlyphInfo] = [:]
        var rectangleIndices: [SIMD4<UInt16>: UInt32] = [:]
        var clusterCache: [ClusterKey: GlyphInfo] = [:]
        private var nextOrigin: (x: Int, y: Int)
        private var rowHeight: Int

        /// - Parameter regionOrigin: the page's corner in the atlas texture.
        /// - Parameter regionSize: the page's extent in texels.
        /// - Parameter reservedFirstRow: skip the first row, which holds the
        ///   opaque texel at the origin that cursor and selection quads share
        ///   the glyph pipeline through (for `asciiPage`; never evicted).
        init(regionOrigin: (x: Int, y: Int), regionSize: (width: Int, height: Int), reservedFirstRow: Bool) {
            self.regionOrigin = regionOrigin
            self.regionSize = regionSize
            self.nextOrigin = reservedFirstRow ? (regionOrigin.x, regionOrigin.y + 1) : regionOrigin
            self.rowHeight = reservedFirstRow ? 1 : 0
        }

        func allocate(width: Int, height: Int) -> (x: Int, y: Int)? {
            guard width <= regionSize.width, height <= regionSize.height else { return nil }
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

    /// The virtual ceiling, after fallback; physical texture height grows.
    private(set) var atlasPixelSize: Int
    /// Allocation fell back to a smaller size; capacity is reduced.
    private(set) var isDegraded = false
    var texture: MTLTexture
    /// Premultiplied bgra, as `CTRunDraw` produces and the color pipeline
    /// blends.
    var colorTexture: MTLTexture
    private(set) var atlasRects: [SIMD4<UInt16>] = [] {
        didSet { atlasRectsVersion = Self.nextRectsVersion.wrappingAdd(1, ordering: .relaxed).newValue }
    }
    /// Changes with every edit of `atlasRects`, unique across atlases, so a
    /// backend re-uploads the table only when it changed.
    private(set) var atlasRectsVersion: UInt64 = 0
    private static let nextRectsVersion = Atomic<UInt64>(0)
    var freeRectangleIndices: [UInt32] = []
    func rectangleIndex(page: AtlasPage, x: Int, y: Int, width: Int, height: Int) -> UInt32 {
        let rect = SIMD4<UInt16>(UInt16(x), UInt16(y), UInt16(width), UInt16(height))
        if let index = page.rectangleIndices[rect] { return index }
        let index: UInt32
        if let free = freeRectangleIndices.popLast() {
            index = free; atlasRects[Int(index) - 1] = rect
        } else {
            index = UInt32(atlasRects.count + 1); atlasRects.append(rect)
        }
        page.rectangleIndices[rect] = index
        return index
    }
    private func clearRectangleTable() {
        atlasRects.removeAll(keepingCapacity: true)
        freeRectangleIndices.removeAll(keepingCapacity: true)
        for page in [asciiPage, shapedPage, colorPage] { page.rectangleIndices.removeAll(keepingCapacity: true) }
    }

    /// Indexed by `Style.rawValue`, with whether each bold is synthetic.
    var fonts: [CTFont]
    var isSyntheticBold: [Bool]
    /// `fonts` with Hiragino Sans, then Apple SD Gothic Neo, leading the
    /// cascade: kana and Hangul take their own script's face whatever the
    /// user's language, which only decides the face for Han.
    var kanaFonts: [CTFont]
    var hangulFonts: [CTFont]
    /// Line spacing, fallback and emoji, as the configuration says.
    var options: TextOptions
    /// The two-cell box a color glyph is rasterised to fit, in pixels.
    var colorBox: CGSize

    /// Font-sized ASCII region at the top of the grayscale texture.
    var asciiPage: AtlasPage
    /// The ASCII page's glyphs, indexed by `(style << 7) | scalar`: the
    /// per-cell lookup is an index, not a hash. A `let` buffer, not an
    /// array in a `var`, so the read carries no exclusivity check; cleared
    /// with the page.
    let asciiTable: UnsafeMutableBufferPointer<GlyphInfo?>
    /// Shaped region below the ASCII shelves.
    private var shapedPage: AtlasPage
    /// The whole color texture.
    var colorPage: AtlasPage

    /// Test counters: the ASCII path never shapes; fallback and eviction fire.
    private(set) var fastPathHits = 0
    private(set) var shapingHits = 0
    var fallbackHits = 0
    /// Page resets, across all pages.
    var evictionCount = 0
    /// Bumped on any page's eviction; earlier UVs may be stale.
    var generation = 0

    /// Whether a committed frame may still sample the current textures. A
    /// reset or eviction then moves to fresh textures instead of rewriting
    /// these: a frame already queued drew glyphs from the new font, or
    /// another glyph, at the UVs it had recorded for the old one. Set by
    /// the renderer; `false` rewrites in place, as nothing reads them.
    var texturesInUse: () -> Bool = { false }
    /// A texture the atlas stopped using while frames still read it; the
    /// renderer lets it go once they complete.
    var onTextureRetired: (MTLTexture) -> Void = { _ in }
    /// Textures moved away from, for tests.
    var textureReplacementCount = 0
    let storageMode: MTLStorageMode
    let allocateTexture: (MTLTextureDescriptor) -> MTLTexture?

    /// Shapes `glyph(shaping:)` and `glyph(forCluster:)` may still run before
    /// `beginFrame` is called again; unlimited outside a frame. A screen of
    /// more distinct clusters than a page holds evicted and re-shaped all of
    /// them on every frame that touched a row — on the main thread every
    /// window shares — so a frame shapes at most this many and leaves the
    /// rest for the next (`deferredShaping`).
    private var shapingAllowance = Int.max
    /// A lookup this frame missed the cache with no allowance left and drew
    /// nothing; the caller decides whether another frame is worth asking for.
    private(set) var deferredShaping = false

    /// Starts a frame's shaping budget.
    func beginFrame(shapingBudget: Int) {
        shapingAllowance = max(0, shapingBudget)
        deferredShaping = false
    }

    /// One shape from the frame's budget, or `false` (and a deferral) once
    /// it is spent.
    private func takeShapingAllowance() -> Bool {
        guard shapingAllowance > 0 else {
            deferredShaping = true
            return false
        }
        shapingAllowance -= 1
        return true
    }

    /// - Parameter device: the GPU the atlas texture lives on.
    /// - Parameter font: the primary font, rasterised at its own size.
    /// - Parameter atlasPixelSize: the square atlas edge; tests pass a small
    ///   one to exercise eviction.
    /// - Parameter storageMode: the texture's storage; tests measure each.
    /// - Parameter makeTexture: a test hook to fail allocations; nil uses the
    ///   device.
    init(
        device: MTLDevice, font: CTFont, atlasPixelSize: Int = GlyphAtlas.atlasSize,
        storageMode: MTLStorageMode = .shared,
        options: TextOptions = TextOptions(),
        makeTexture: ((MTLTextureDescriptor) -> MTLTexture?)? = nil
    ) throws {
        // Pinned here too, so the atlas is the one choke point for the cascade.
        let base = TerminalFont.pinningCascadeList(font, size: CTFontGetSize(font), cjk: options.cjkFamily)
        (self.fonts, self.isSyntheticBold) = Self.faces(of: base, cjk: options.cjkFamily)
        (self.kanaFonts, self.hangulFonts) = Self.scriptFaces(of: fonts, cjk: options.cjkFamily)
        self.options = options
        self.colorBox = Self.colorBox(for: base, lineSpacing: options.lineSpacing)

        let allocate = makeTexture ?? { device.makeTexture(descriptor: $0) }
        self.allocateTexture = allocate
        self.storageMode = storageMode
        // Halve and retry down to `minimumAtlasPixelSize`, then give up — as a
        // thrown error the pane shows as a renderer failure, where a trap took
        // every window down with it.
        var size = max(1, atlasPixelSize)
        var allocated: (gray: MTLTexture, color: MTLTexture)?
        while true {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm, width: size, height: min(128, size), mipmapped: false)
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = storageMode
            let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
            colorDescriptor.usage = [.shaderRead]
            colorDescriptor.storageMode = storageMode
            if let gray = allocate(descriptor), let color = allocate(colorDescriptor) {
                allocated = (gray, color)
                break
            }
            guard size > Self.minimumAtlasPixelSize else { break }
            size = max(size / 2, Self.minimumAtlasPixelSize)
        }
        guard let allocated else {
            throw GlyphAtlasError.textureUnavailable(minimumPixelSize: Self.minimumAtlasPixelSize)
        }
        self.texture = allocated.gray
        self.colorTexture = allocated.color
        self.atlasPixelSize = size
        self.isDegraded = size < atlasPixelSize

        (self.asciiPage, self.shapedPage, self.colorPage) = Self.makePages(atlasPixelSize: size, font: base)
        asciiTable = .allocate(capacity: 4 << 7)
        asciiTable.initialize(repeating: nil)

        var white: UInt8 = 255
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 1)
    }

    deinit {
        asciiTable.deallocate()
    }

    /// Two cells of `font`, which is already in pixels: the renderer's box
    /// for a wide glyph, so an emoji drawn to fit it is never scaled on the
    /// GPU.
    static func colorBox(for font: CTFont, lineSpacing: CGFloat) -> CGSize {
        let metrics = CellMetrics(font: font, lineSpacing: lineSpacing)
        return CGSize(width: metrics.cellWidth * 2, height: metrics.cellHeight)
    }

    /// The three pages' fixed regions, fresh each call so `init` and `reset`
    /// never rewind them by hand.
    private static func makePages(atlasPixelSize: Int, font: CTFont) -> (ascii: AtlasPage, shaped: AtlasPage, color: AtlasPage) {
        let metrics = CellMetrics(font: font)
        // Reserve complete shelves for 95 printable glyphs in each face. Keep
        // the tiny test/fallback atlas split, so eviction remains exercised.
        let glyphWidth = max(1, Int(ceil(metrics.cellWidth)) + 4)
        let shelfHeight = max(1, Int(ceil(metrics.cellHeight)) + 4)
        let perShelf = max(1, atlasPixelSize / glyphWidth)
        let required = 1 + ((95 * 4 + perShelf - 1) / perShelf) * shelfHeight
        let asciiHeight = min(atlasPixelSize / 2, required)
        let ascii = AtlasPage(
            regionOrigin: (0, 0), regionSize: (atlasPixelSize, asciiHeight), reservedFirstRow: true)
        let shaped = AtlasPage(
            regionOrigin: (0, asciiHeight), regionSize: (atlasPixelSize, atlasPixelSize - asciiHeight),
            reservedFirstRow: false)
        let color = AtlasPage(
            regionOrigin: (0, 0), regionSize: (atlasPixelSize, atlasPixelSize), reservedFirstRow: false)
        return (ascii, shaped, color)
    }

    /// Re-points the atlas at a new font, shrinking textures and keeping pipelines:
    /// ⌘= / ⌘- call this per key repeat.
    func reset(font newFont: CTFont, options newOptions: TextOptions? = nil) {
        if let newOptions { options = newOptions }
        let base = TerminalFont.pinningCascadeList(newFont, size: CTFontGetSize(newFont), cjk: options.cjkFamily)
        (fonts, isSyntheticBold) = Self.faces(of: base, cjk: options.cjkFamily)
        (kanaFonts, hangulFonts) = Self.scriptFaces(of: fonts, cjk: options.cjkFamily)
        colorBox = Self.colorBox(for: base, lineSpacing: options.lineSpacing)
        (asciiPage, shapedPage, colorPage) = Self.makePages(atlasPixelSize: atlasPixelSize, font: base)
        asciiTable.update(repeating: nil)
        evictionCount += 1
        generation += 1
        clearRectangleTable()
        if texturesInUse() || texture.height > min(128, atlasPixelSize) {
            replaceTexture(.grayscale, copying: false, height: min(128, atlasPixelSize))
        }
        if colorTexture.width != 1 {
            replaceTexture(.color, copying: false, height: 1, width: 1)
        }
        var white: UInt8 = 255
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 1)
    }

    /// The four faces of `base` and their synthetic-bold flags
    /// (`TerminalFont.variant`).
    private static func faces(of base: CTFont, cjk: String?) -> ([CTFont], [Bool]) {
        var fonts: [CTFont] = []
        var synthetic: [Bool] = []
        for rawValue in UInt8(0)...UInt8(3) {
            let style = Style(rawValue: rawValue)
            let derived = TerminalFont.variant(
                of: base, bold: style.rawValue & 1 != 0, italic: style.rawValue & 2 != 0, cjk: cjk)
            fonts.append(derived.font)
            synthetic.append(derived.syntheticBold)
        }
        return (fonts, synthetic)
    }

    /// Each face re-pinned with a kana or Hangul lead; the faces themselves,
    /// and so their bold and italic, are unchanged. A chosen CJK family
    /// still goes first: the user picked it for every script.
    private static func scriptFaces(of fonts: [CTFont], cjk: String?) -> ([CTFont], [CTFont]) {
        func pinned(_ lead: TerminalFont.CJKLead) -> [CTFont] {
            fonts.map { TerminalFont.pinningCascadeList($0, size: CTFontGetSize($0), lead: lead, cjk: cjk) }
        }
        return (pinned(.japanese), pinned(.korean))
    }

    /// ASCII fast path — see the type comment. The renderer passes only
    /// ASCII, looked up by index; anything else keeps a dictionary entry.
    /// Inlined into the per-cell loop: a hit is one load. A miss leaves it.
    @inline(__always)
    func glyph(forASCII scalar: UInt32, style: Style) -> GlyphInfo? {
        if scalar < 0x80, let cached = asciiTable[Int(style.rawValue) << 7 | Int(scalar)] { return cached }
        return rasterizeASCII(scalar, style: style)
    }

    @inline(never)
    private func rasterizeASCII(_ scalar: UInt32, style: Style) -> GlyphInfo? {
        let index = scalar < 0x80 ? Int(style.rawValue) << 7 | Int(scalar) : nil
        if index == nil, let cached = asciiPage.cache[GlyphKey(scalar: scalar, style: style)] {
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
            asciiTable[index] = info
        } else {
            asciiPage.cache[GlyphKey(scalar: scalar, style: style)] = info
        }
    }

    /// Non-ASCII single scalars, shaped once per key.
    func glyph(shaping scalar: UInt32, style: Style) -> GlyphInfo? {
        let key = GlyphKey(scalar: scalar, style: style)
        if let cached = shapedPage.cache[key] ?? colorPage.cache[key] { return cached }
        guard let scalarValue = Unicode.Scalar(scalar), takeShapingAllowance() else { return nil }
        shapingHits += 1
        let shaped = shape(String(Character(scalarValue)), style: style)
        let page = cachePage(for: shaped.runs)
        prepareCache(page)
        var info = rasterize(shaped.runs, style: style, page: shapedPage)
        if shaped.runs.isEmpty, shaped.sawNotdef { info.isMissing = true }
        page.cache[key] = info
        return info
    }

    /// Shapes the whole cluster as one string, so ZWJ sequences and combining
    /// marks come out as the font defines them.
    func glyph(forCluster scalars: [UInt32], style: Style) -> GlyphInfo? {
        guard scalars.count <= GraphemeTable.maximumClusterScalars else { return nil }
        let key = ClusterKey(scalars: scalars, style: style)
        if let cached = shapedPage.clusterCache[key] ?? colorPage.clusterCache[key] { return cached }
        var view = String.UnicodeScalarView()
        for scalar in scalars {
            guard let value = Unicode.Scalar(scalar) else { return nil }
            view.append(value)
        }
        guard !view.isEmpty, takeShapingAllowance() else { return nil }
        shapingHits += 1
        let shaped = shape(String(view), style: style)
        let page = cachePage(for: shaped.runs)
        prepareCache(page)
        var info = rasterize(shaped.runs, style: style, page: shapedPage)
        if shaped.runs.isEmpty, shaped.sawNotdef { info.isMissing = true }
        page.clusterCache[key] = info
        return info
    }

    /// Inkless/notdef results consume no shelf space, so also bound keys.
    private func prepareCache(_ page: AtlasPage) {
        if page.cache.count + page.clusterCache.count >= 4096 { evict(page) }
    }

    private func cachePage(for runs: [ShapedRun]) -> AtlasPage {
        runs.contains(where: { $0.isColor }) ? colorPage : shapedPage
    }

    /// One shaped run and the font it actually used; `ctRun` for color runs.
    ///
    /// `ctLine` is held only to keep `ctRun` valid: a run's glyph storage
    /// belongs to its line, and once the line was freed
    /// `CTRunGetImageBounds` crashed intermittently.
    typealias ShapedRun = (
        glyphs: [CGGlyph], positions: [CGPoint], font: CTFont, isColor: Bool,
        ctRun: CTRun?, ctLine: CTLine?
    )

    enum TextureKind: Hashable { case grayscale, color }
    /// Failed retirement allocation must never let a later miss overwrite
    /// texels referenced by an in-flight frame.
    var blockedTextureWrites: Set<TextureKind> = []

}
