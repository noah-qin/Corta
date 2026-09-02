import CoreGraphics
import CoreText
import CortaTerminal
import Metal
import Testing

@testable import Corta

/// M4.4, renderer side: search matches paint as overlay quads, the current
/// match reads differently from the rest, and the overlay moves with the
/// scroll offset exactly like a selection does.
/// `.serialized`: these build a `GlyphAtlas`, which is single-threaded
/// by design — see the type's comment.
@Suite(.serialized) struct SearchHighlightRenderTests {
    private static func pixel(of texture: MTLTexture, x: Int, y: Int) -> (
        r: UInt8, g: UInt8, b: UInt8, a: UInt8
    ) {
        var bytes = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return (r: bytes[2], g: bytes[1], b: bytes[0], a: bytes[3])
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

    private struct Fixture {
        let renderer: TerminalRenderer
        let queue: MTLCommandQueue
        let width: Int
        let height: Int
    }

    private static func fixture() throws -> Fixture? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let renderer = try TerminalRenderer(device: device, font: font, scale: 1)
        return Fixture(
            renderer: renderer, queue: device.makeCommandQueue()!,
            width: Int(renderer.metrics.cellWidth * 10),
            height: Int(renderer.metrics.cellHeight * 4))
    }

    @discardableResult
    private static func draw(
        _ fixture: Fixture, grid: Grid, scrollOffset: Int,
        searchMatches: [TerminalSelection], currentSearchMatchIndex: Int?
    ) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: QuadRenderer.pixelFormat, width: fixture.width, height: fixture.height,
            mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        let texture = fixture.renderer.quadRenderer.device.makeTexture(descriptor: descriptor)!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
        let commandBuffer = fixture.queue.makeCommandBuffer()!
        fixture.renderer.render(
            grid: grid, scrollOffset: scrollOffset,
            rect: CGRect(x: 0, y: 0, width: fixture.width, height: fixture.height),
            drawableSize: CGSize(width: fixture.width, height: fixture.height),
            cursorVisible: false, selection: nil,
            searchMatches: searchMatches, currentSearchMatchIndex: currentSearchMatchIndex,
            renderPassDescriptor: pass, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        Self.synchronize(texture, queue: fixture.queue)
        return texture
    }

    private static func cellCenter(
        _ fixture: Fixture, column: Int, row: Int
    ) -> (x: Int, y: Int) {
        (
            x: Int((Float(column) + 0.5) * Float(fixture.renderer.metrics.cellWidth)),
            y: Int((Float(row) + 0.5) * Float(fixture.renderer.metrics.cellHeight))
        )
    }

    /// Two matches on otherwise blank columns: row 1 and row 2 of a 10x4
    /// grid, both over columns 4...8 so glyph ink never confuses the tint.
    @Test func matchesHighlightAndTheCurrentOneReadsDifferently() throws {
        guard let fixture = try Self.fixture() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let grid = Grid(rows: 4, columns: 10)
        let matches = [1, 2].map { row in
            TerminalSelection(
                start: GridPosition(row: row, column: 4),
                end: GridPosition(row: row, column: 8))
        }

        let plain = Self.draw(
            fixture, grid: grid, scrollOffset: 0, searchMatches: matches,
            currentSearchMatchIndex: nil)
        let row1 = Self.cellCenter(fixture, column: 6, row: 1)
        let row2 = Self.cellCenter(fixture, column: 6, row: 2)
        let outside = Self.cellCenter(fixture, column: 2, row: 1)
        // The pass clears to opaque black, so tint shows in the colour
        // channels: the match colour (0.85, 0.75, 0.2) is dominantly red.
        #expect(Self.pixel(of: plain, x: row1.x, y: row1.y).r > 0, "a match paints its cells")
        #expect(
            Self.pixel(of: plain, x: outside.x, y: outside.y).r == 0,
            "cells outside every match stay clear")

        let withCurrent = Self.draw(
            fixture, grid: grid, scrollOffset: 0, searchMatches: matches,
            currentSearchMatchIndex: 1)
        // (0.95, 0.55, 0.15) at 0.6 alpha premultiplies to more red than
        // (0.85, 0.75, 0.2) at 0.35.
        #expect(
            Self.pixel(of: withCurrent, x: row2.x, y: row2.y).r
                > Self.pixel(of: withCurrent, x: row1.x, y: row1.y).r,
            "the current match paints more strongly than the others")
    }
}
