import AppKit
import CoreGraphics
import CoreText
import CortaTerminal
import Metal
import Testing

@testable import Corta

/// The font stack (`TerminalFont`) and color emoji rendering: the primary is
/// the system monospaced font, the pinned cascade resolves CJK to PingFang
/// SC and emoji to Apple Color Emoji, and color glyphs rasterise — in color —
/// into the atlas's RGBA texture and draw through the color pipeline.
/// `.serialized`: these build a `GlyphAtlas`, which is single-threaded
/// by design — see the type's comment.
@Suite(.serialized) struct ColorEmojiRenderTests {
    private static func makeDevice() -> MTLDevice? { MTLCreateSystemDefaultDevice() }

    private static func synchronize(_ texture: MTLTexture, queue: MTLCommandQueue) {
        guard texture.storageMode == .managed, let buffer = queue.makeCommandBuffer(),
            let blit = buffer.makeBlitCommandEncoder()
        else { return }
        blit.synchronize(resource: texture)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    /// Renders `grid` onto a fresh black texture sized exactly to the grid
    /// (same harness as `WideGlyphRenderTests`).
    private static func render(
        _ grid: Grid, renderer: TerminalRenderer, queue: MTLCommandQueue, device: MTLDevice
    ) -> MTLTexture {
        let width = Int(renderer.metrics.cellWidth) * grid.columns
        let height = Int(renderer.metrics.cellHeight) * grid.rows
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: QuadRenderer.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        let texture = device.makeTexture(descriptor: descriptor)!

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store

        let commandBuffer = queue.makeCommandBuffer()!
        renderer.render(
            grid: grid, rect: CGRect(x: 0, y: 0, width: width, height: height),
            drawableSize: CGSize(width: width, height: height), cursorVisible: false,
            selection: nil, renderPassDescriptor: pass, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        Self.synchronize(texture, queue: queue)
        return texture
    }

    /// Counts pixels in `texture`'s `region` that have ink (a > 0) and that
    /// are colored (r, g, b not all equal). bgra byte order.
    private static func inkAndColor(
        in texture: MTLTexture, region: MTLRegion
    ) -> (inked: Int, colored: Int) {
        let width = region.size.width, height = region.size.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: region, mipmapLevel: 0)
        var inked = 0
        var colored = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let b = bytes[i], g = bytes[i + 1], r = bytes[i + 2], a = bytes[i + 3]
            guard a > 0 else { continue }
            inked += 1
            if !(r == g && g == b) { colored += 1 }
        }
        return (inked, colored)
    }

    @Test func primaryFontIsTheSystemMonospacedFontWithAPinnedCascade() {
        let expected = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        let primary = TerminalFont.primary(ofSize: 15)
        #expect(CTFontCopyPostScriptName(primary) as String == expected.fontName)
        let attributes = CTFontDescriptorCopyAttributes(CTFontCopyFontDescriptor(primary))
            as? [CFString: Any]
        let cascade = attributes?[kCTFontCascadeListAttribute] as? [CTFontDescriptor]
        #expect(cascade?.count == 2)
    }

    /// The pinned cascade, asserted where it is assertable: shape 中 with the
    /// primary font and inspect the fallback run's font directly.
    @Test func cjkFallsBackToThePinnedPingFangSC() throws {
        let font = TerminalFont.primary(ofSize: 14)
        let attributed = CFAttributedStringCreate(
            nil, "中" as CFString, [kCTFontAttributeName: font] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], runs.count == 1 else {
            Issue.record("expected a single glyph run for 中")
            return
        }
        let runAttributes = CTRunGetAttributes(runs[0]) as? [CFString: Any]
        guard let fontAttribute = runAttributes?[kCTFontAttributeName] else {
            Issue.record("the 中 run carries no font attribute")
            return
        }
        // A run's font attribute is always a CTFont; the conditional above
        // is only about the key's presence.
        let runFont = fontAttribute as! CTFont
        #expect((CTFontCopyPostScriptName(runFont) as String).hasPrefix("PingFangSC"))
        #expect(!CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs))
    }

    /// An emoji scalar rasterises non-blank and *colored* into the color
    /// atlas — the grayscale coverage path drew nothing for bitmap glyphs.
    @Test func emojiRasterisesNonBlankAndInColor() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let atlas = GlyphAtlas(device: device, font: TerminalFont.primary(ofSize: 32))

        guard let info = atlas.glyph(shaping: 0x1F600, bold: false), info.size != .zero  // 😀
        else {
            Issue.record("😀 failed to shape in this environment")
            return
        }
        #expect(info.isColor, "the emoji run must be detected as a color font")
        #expect(atlas.fallbackHits > 0, "the emoji run must come from the cascade list")

        let originX = Int(info.uvRect.x * Float(atlas.atlasPixelSize))
        let originY = Int(info.uvRect.y * Float(atlas.atlasPixelSize))
        let region = MTLRegionMake2D(originX, originY, Int(info.size.x), Int(info.size.y))
        Self.synchronize(atlas.colorTexture, queue: device.makeCommandQueue()!)
        let result = Self.inkAndColor(in: atlas.colorTexture, region: region)
        #expect(result.inked > 0, "expected ink in the emoji's atlas rect")
        #expect(result.colored > 0, "expected at least one non-grey pixel — emoji render in color")
    }

    /// A CJK scalar keeps rasterising through the grayscale path, with the
    /// fallback attributed to the cascade (PingFang SC, per the factory-level
    /// assertion above).
    @Test func cjkStillRasterisesThroughTheGrayscalePath() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let atlas = GlyphAtlas(device: device, font: TerminalFont.primary(ofSize: 32))

        let info = atlas.glyph(shaping: 0x4E2D, bold: false)  // 中
        #expect(info != nil)
        #expect(info?.size != .zero)
        #expect(info?.isColor == false)
        #expect(atlas.fallbackHits > 0)
    }

    /// End to end: 😀 through the grid and the renderer inks its two-cell
    /// box in color — exercising the third draw call and the wide-glyph
    /// scale-and-centre path for color quads.
    @Test func emojiRendersInColorThroughTheRenderer() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let queue = device.makeCommandQueue()!
        let renderer = try TerminalRenderer(
            device: device, font: TerminalFont.primary(ofSize: 14), scale: 1)

        var terminal = Terminal(rows: 2, columns: 6)
        terminal.feed(Array("😀".utf8))
        let grid = terminal.grid
        #expect(grid[0, 0].attributes.contains(.wide))

        let texture = Self.render(grid, renderer: renderer, queue: queue, device: device)
        let cellWidth = Int(renderer.metrics.cellWidth)
        let cellHeight = Int(renderer.metrics.cellHeight)
        let box = MTLRegionMake2D(0, 0, cellWidth * 2, cellHeight)
        let result = Self.inkAndColor(in: texture, region: box)
        #expect(result.inked > 0, "expected the emoji to ink its two-cell box")
        #expect(result.colored > 0, "expected colored pixels in the rendered emoji")
    }

    /// Same end to end for a ZWJ cluster (👨‍👩‍👧‍👦): the core collapses the
    /// sequence into one wide cluster cell (`Grid.write`'s M3.6 path), and
    /// the cluster must rasterise in color exactly like a single scalar.
    /// Runs at scale 2 as well — the live app rasterises its atlas at
    /// `font size * backingScale`.
    @Test(arguments: [1.0, 2.0])
    func zwjClusterRendersInColorThroughTheRenderer(scale: Double) throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let queue = device.makeCommandQueue()!
        let renderer = try TerminalRenderer(
            device: device, font: TerminalFont.primary(ofSize: 14), scale: scale)

        var terminal = Terminal(rows: 2, columns: 6)
        terminal.feed(Array("👨‍👩‍👧‍👦".utf8))
        let grid = terminal.grid
        #expect(grid[0, 0].attributes.contains(.wide))
        #expect(!grid[0, 0].grapheme.isNone)

        let texture = Self.render(grid, renderer: renderer, queue: queue, device: device)
        let cellWidth = Int(renderer.metrics.cellWidth)
        let cellHeight = Int(renderer.metrics.cellHeight)
        let box = MTLRegionMake2D(0, 0, cellWidth * 2, cellHeight)
        let result = Self.inkAndColor(in: texture, region: box)
        #expect(result.inked > 0, "expected the family emoji to ink its two-cell box")
        #expect(result.colored > 0, "expected the family emoji to render in color, not gray")
    }
}
