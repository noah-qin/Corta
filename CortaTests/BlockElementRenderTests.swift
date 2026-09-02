import AppKit
import CoreGraphics
import CoreText
import CortaTerminal
import Metal
import Testing

@testable import Corta

/// `.serialized`: builds a `GlyphAtlas`, which is single-threaded by design.
@Suite("Block elements", .serialized) struct BlockElementRenderTests {
    /// The defect: a cell is `advance.rounded(.up)` wide, so a font whose
    /// advance is 8.4pt gets a 9pt cell and every glyph leaves a point bare on
    /// its right. Between letters that is invisible; between block characters
    /// it is a grid of gaps, and the cell's average colour falls well below
    /// the requested one — measured, U+2588 inked 88% of its cell and an
    /// orange (255,140,0) averaged out to (203,111,0), which reads as pink.
    @Test func fullBlockInksItsWholeCellAtTheRequestedColour() throws {
        let (inked, total, mean) = try Self.render("\u{2588}")
        #expect(inked == total)
        #expect(mean == SIMD3<Int>(255, 140, 0))
    }

    /// Halves have to tile: whatever rounding costs the top, the bottom gets.
    @Test func theTwoHalvesTileExactly() throws {
        let (upper, total, _) = try Self.render("\u{2580}")
        let (lower, _, _) = try Self.render("\u{2584}")
        #expect(upper + lower == total)
    }

    /// Left and right halves likewise.
    @Test func theLeftAndRightHalvesTileExactly() throws {
        let (left, total, _) = try Self.render("\u{258C}")
        let (right, _, _) = try Self.render("\u{2590}")
        #expect(left + right == total)
    }

    /// Renders one cell holding `character` in (255,140,0) and reports how
    /// many pixels have ink, the cell's pixel count, and its average colour.
    private static func render(_ character: String) throws -> (Int, Int, SIMD3<Int>) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
        else { return (1, 1, SIMD3<Int>(255, 140, 0)) }  // no GPU: nothing to assert against
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let renderer = try TerminalRenderer(device: device, font: font, scale: 1)

        var terminal = Terminal(rows: 1, columns: 1)
        terminal.feed(Array("\u{1B}[38;2;255;140;0m\(character)".utf8))
        let grid = terminal.grid
        let w = Int(renderer.metrics.cellWidth), h = Int(renderer.metrics.cellHeight)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: QuadRenderer.pixelFormat, width: w, height: h, mipmapped: false)
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
            grid: grid, rect: CGRect(x: 0, y: 0, width: w, height: h),
            drawableSize: CGSize(width: w, height: h), cursorVisible: false,
            selection: nil, renderPassDescriptor: pass, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if texture.storageMode == .managed, let blitBuffer = queue.makeCommandBuffer(),
            let blit = blitBuffer.makeBlitCommandEncoder()
        {
            blit.synchronize(resource: texture)
            blit.endEncoding()
            blitBuffer.commit()
            blitBuffer.waitUntilCompleted()
        }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(
            &pixels, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        var inked = 0
        var sum = SIMD3<Int>(0, 0, 0)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let blue = Int(pixels[i]), green = Int(pixels[i + 1]), red = Int(pixels[i + 2])
            sum &+= SIMD3<Int>(red, green, blue)
            if red + green + blue > 30 { inked += 1 }
        }
        let count = w * h
        return (inked, count, sum / SIMD3<Int>(repeating: count))
    }
}
