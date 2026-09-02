import CoreGraphics
import CoreText
import CortaTerminal
import Metal
import Testing

@testable import Corta

/// M3.5/M3.6 — wide glyphs and grapheme clusters in the renderer: a wide
/// pair's glyph is scaled into and centred on its two-cell box, clusters are
/// shaped as one run, and no glyph ever inks a cell that is not its own.
/// `.serialized`: these build a `GlyphAtlas`, which is single-threaded
/// by design — see the type's comment.
@Suite(.serialized) struct WideGlyphRenderTests {
    private static func pixel(of texture: MTLTexture, x: Int, y: Int) -> UInt8 {
        var bytes = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return bytes[2]  // r of bgra
    }

    private static func synchronize(_ texture: MTLTexture, queue: MTLCommandQueue) {
        guard texture.storageMode == .managed, let buffer = queue.makeCommandBuffer(),
            let blit = buffer.makeBlitCommandEncoder()
        else { return }
        blit.synchronize(resource: texture)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    /// Renders `grid` onto a fresh black texture sized exactly to the grid.
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

    private static func makeRenderer(
        device: MTLDevice, atlasPixelSize: Int = GlyphAtlas.atlasSize
    ) throws -> TerminalRenderer {
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        return try TerminalRenderer(device: device, font: font, scale: 1, atlasPixelSize: atlasPixelSize)
    }

    /// Every pixel column of `column`'s cell on `row` must be background —
    /// the no-spill assertion, checked over the whole cell rather than a
    /// point sample because a scaled glyph's ink can dodge any single point.
    private static func cellIsBlank(
        _ texture: MTLTexture, row: Int, column: Int, metrics: CellMetrics
    ) -> Bool {
        let cellWidth = Int(metrics.cellWidth)
        let cellHeight = Int(metrics.cellHeight)
        var bytes = [UInt8](repeating: 0, count: cellWidth * cellHeight * 4)
        texture.getBytes(
            &bytes, bytesPerRow: cellWidth * 4,
            from: MTLRegionMake2D(column * cellWidth, row * cellHeight, cellWidth, cellHeight),
            mipmapLevel: 0)
        for i in stride(from: 2, to: bytes.count, by: 4) where bytes[i] != 0 { return false }
        return true
    }

    /// M3.5: 中 must ink BOTH cells of its pair — before, the lead's glyph
    /// was drawn into a single cell — and nothing may spill into the cell
    /// after the pair.
    @Test func wideGlyphCoversItsWholePairAndNeverTheNextCell() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let queue = device.makeCommandQueue()!
        let renderer = try Self.makeRenderer(device: device)

        var terminal = Terminal(rows: 2, columns: 6)
        terminal.feed(Array("中".utf8))
        let grid = terminal.grid
        #expect(grid[0, 0].attributes.contains(.wide))

        let texture = Self.render(grid, renderer: renderer, queue: queue, device: device)
        let cellWidth = Int(renderer.metrics.cellWidth)
        let cellHeight = Int(renderer.metrics.cellHeight)
        let centreY = cellHeight / 2
        let leadInk = Self.pixel(of: texture, x: cellWidth / 2, y: centreY)
        let spacerInk = Self.pixel(of: texture, x: cellWidth + cellWidth / 2, y: centreY)

        #expect(leadInk > 0, "expected ink in the pair's lead cell")
        #expect(spacerInk > 0, "expected the wide glyph to cover the spacer's cell too")
        #expect(
            Self.cellIsBlank(texture, row: 0, column: 2, metrics: renderer.metrics),
            "ink spilled into the cell after the pair")
    }

    /// A row of wide pairs still aligns with the grid: the cell holding the
    /// narrow scalar after three pairs stays blank except its own glyph.
    @Test func mixedCJKAndASCIIStaysOnTheGrid() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let queue = device.makeCommandQueue()!
        let renderer = try Self.makeRenderer(device: device)

        var terminal = Terminal(rows: 2, columns: 8)
        terminal.feed(Array("中文ab".utf8))
        let grid = terminal.grid
        #expect(grid.cursor == Cursor(row: 0, column: 6))

        let texture = Self.render(grid, renderer: renderer, queue: queue, device: device)
        // The 'a' lives at column 4; columns 5 ('b') and beyond shift if any
        // pair drew at the wrong width.
        let cellWidth = Int(renderer.metrics.cellWidth)
        let cellHeight = Int(renderer.metrics.cellHeight)
        let aInk = Self.pixel(of: texture, x: 4 * cellWidth + cellWidth / 2, y: cellHeight / 2)
        #expect(aInk > 0, "expected 'a' at column 4, undrifted by the wide pairs before it")
        #expect(
            Self.cellIsBlank(texture, row: 0, column: 6, metrics: renderer.metrics),
            "unexpected ink past the written text")
    }

    /// M3.6: a combining mark joins the previous cell's cluster and the
    /// cluster is shaped as one run — e + U+0301 renders é within its single
    /// cell, leaving the next cell blank.
    @Test func combiningClusterRendersWithinItsCell() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let queue = device.makeCommandQueue()!
        let renderer = try Self.makeRenderer(device: device)

        var terminal = Terminal(rows: 2, columns: 6)
        terminal.feed(Array("e\u{301}".utf8))
        let grid = terminal.grid
        #expect(!grid[0, 0].grapheme.isNone)
        #expect(grid.cursor == Cursor(row: 0, column: 1))

        let texture = Self.render(grid, renderer: renderer, queue: queue, device: device)
        let cellWidth = Int(renderer.metrics.cellWidth)
        let cellHeight = Int(renderer.metrics.cellHeight)
        let ink = Self.pixel(of: texture, x: cellWidth / 2, y: cellHeight / 2)
        #expect(ink > 0, "expected the é cluster to ink its cell")
        #expect(
            Self.cellIsBlank(texture, row: 0, column: 1, metrics: renderer.metrics),
            "a combining cluster spilled past its cell")
    }

    /// M3.6: a combining mark after a wide pair joins the pair's lead cell
    /// (core behaviour, `WideWriteTests`), and the wide cluster is scaled
    /// into the two-cell box — the cell after the pair stays blank even
    /// though U+20D0's enclosing circle widens the ink.
    @Test func combiningMarkOnAWidePairStaysInsideThePair() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let queue = device.makeCommandQueue()!
        let renderer = try Self.makeRenderer(device: device)

        var terminal = Terminal(rows: 2, columns: 6)
        terminal.feed(Array("中\u{20D0}".utf8))
        let grid = terminal.grid
        #expect(!grid[0, 0].grapheme.isNone)
        #expect(grid[0, 0].attributes.contains(.wide))

        let texture = Self.render(grid, renderer: renderer, queue: queue, device: device)
        #expect(
            Self.cellIsBlank(texture, row: 0, column: 2, metrics: renderer.metrics),
            "a wide cluster spilled past its pair")
    }

    /// M3.6 done-when, renderer half: a ZWJ family emoji drawn as the wide
    /// cluster the grid references inks its two-cell box and nothing beyond
    /// it. This builds the quad by hand — it exercises the atlas's cluster
    /// shaping plus the scale-and-centre quad math, not the
    /// `appendRowInstances` colour routing; the full feed→grid→draw path is
    /// covered by `ColorEmojiRenderTests.zwjClusterRendersInColorThroughTheRenderer`.
    @Test func zwjFamilyEmojiRendersInOneDoubleWidthCell() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let queue = device.makeCommandQueue()!
        let renderer = try Self.makeRenderer(device: device)

        // 👨‍👩‍👧‍👦
        let family: [UInt32] = [0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467, 0x200D, 0x1F466]
        guard let info = renderer.glyphAtlas.glyph(forCluster: family, bold: false),
            info.size != .zero
        else {
            Issue.record("the ZWJ family cluster failed to shape in this environment")
            return
        }

        let cellWidth = Float(renderer.metrics.cellWidth)
        let cellHeight = Float(renderer.metrics.cellHeight)
        let baseline = Float(renderer.metrics.baselineOffset)
        let boxWidth = cellWidth * 2
        let fit = min(1, boxWidth / info.size.x, cellHeight / info.size.y)
        let size = info.size * fit
        let origin = SIMD2<Float>(
            (boxWidth - size.x) / 2, baseline - (info.bearing.y + info.size.y) * fit)
        let instance = QuadInstance(origin: origin, size: size, color: .init(1, 1, 1, 1), uvRect: info.uvRect)

        // Three cells wide: the pair's box plus one neighbour.
        let width = Int(cellWidth) * 3
        let height = Int(cellHeight)
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
        // A color emoji bitmaps into the RGBA atlas and draws through the
        // color pipeline (see `GlyphAtlas`'s type comment) — the coverage
        // pipeline would find nothing at these UVs in the grayscale atlas.
        #expect(info.isColor)
        renderer.quadRenderer.drawColorQuads(
            [instance], atlas: renderer.glyphAtlas.colorTexture,
            rect: CGRect(x: 0, y: 0, width: width, height: height),
            drawableSize: CGSize(width: width, height: height),
            renderPassDescriptor: pass, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        Self.synchronize(texture, queue: queue)

        let centreX = Int(cellWidth)  // centre of the two-cell box
        let ink = Self.pixel(of: texture, x: centreX, y: height / 2)
        #expect(ink > 0, "expected the family emoji to ink its double-width cell")
        #expect(
            Self.cellIsBlank(texture, row: 0, column: 2, metrics: renderer.metrics),
            "the family emoji spilled into the neighbouring cell")
    }

    /// M3 eviction: a screen whose content exceeds one atlas page forces a
    /// reset mid-build; the renderer notices the generation bump, rebuilds,
    /// and still draws — no crash, no wedged state.
    @Test func atlasExhaustionDuringRenderRecovers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let queue = device.makeCommandQueue()!
        // A 48×48 page holds ~9 glyphs at 14 pt; the screen below shows 15
        // distinct ones (a 3×10 grid holds five wide pairs per row).
        let renderer = try Self.makeRenderer(device: device, atlasPixelSize: 48)

        var terminal = Terminal(rows: 3, columns: 10)
        var bytes: [UInt8] = []
        for i: UInt32 in 0..<15 {
            bytes.append(contentsOf: Array(String(Unicode.Scalar(0x4E00 + i)!).utf8))
        }
        terminal.feed(bytes)
        let texture = Self.render(terminal.grid, renderer: renderer, queue: queue, device: device)

        #expect(renderer.glyphAtlas.evictionCount > 0, "fifteen CJK glyphs must overflow a 48x48 page")
        var anyInk = false
        for column in 0..<10 {
            if !Self.cellIsBlank(texture, row: 0, column: column, metrics: renderer.metrics) {
                anyInk = true
                break
            }
        }
        #expect(anyInk, "expected at least one glyph to survive the eviction retry")
    }
}
