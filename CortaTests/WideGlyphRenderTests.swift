import CoreGraphics
import CoreText
import CortaTerminal
import Metal
import Testing

@testable import Corta

/// Atlas eviction (M3, `DESIGN.md` §7 hard part 4) seen from the renderer.
struct WideGlyphRenderTests {
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

    /// True when every pixel of `column`'s cell on `row` is background.
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

    /// A screen whose content exceeds one atlas page forces a reset
    /// mid-build; the renderer notices the generation bump, rebuilds, and
    /// still draws — no crash, no wedged state.
    @Test func atlasExhaustionDuringRenderRecovers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let queue = device.makeCommandQueue()!
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        // A 48×48 page holds ~9 glyphs at 14 pt; the screen below shows 15
        // distinct ones (a 3×10 grid holds five wide pairs per row).
        let renderer = try TerminalRenderer(device: device, font: font, scale: 1, atlasPixelSize: 48)

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
