import CoreGraphics
import CoreText
import CortaTerminal
import Metal
import Testing

@testable import Corta

struct TerminalRendererTests {
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

    @Test func cursorBlockRendersAtTheCursorCell() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let queue = device.makeCommandQueue()!
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let renderer = try TerminalRenderer(device: device, font: font)

        var terminal = Terminal(rows: 4, columns: 10)
        terminal.feed(Array("abc".utf8))  // cursor now sits at row 0, column 3
        let grid = terminal.grid

        let width = Int(renderer.metrics.cellWidth * 10)
        let height = Int(renderer.metrics.cellHeight * 4)
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
            drawableSize: CGSize(width: width, height: height), cursorVisible: true, selection: nil,
            renderPassDescriptor: pass, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        Self.synchronize(texture, queue: queue)

        let cursorX = Int(Float(grid.cursor.column) * Float(renderer.metrics.cellWidth) + Float(renderer.metrics.cellWidth) / 2)
        let cursorY = Int(Float(grid.cursor.row) * Float(renderer.metrics.cellHeight) + Float(renderer.metrics.cellHeight) / 2)
        let atCursor = Self.pixel(of: texture, x: cursorX, y: cursorY)
        let elsewhere = Self.pixel(of: texture, x: width - 4, y: height - 4)

        // The cursor block is a translucent grey over black — brighter than
        // the untouched background, which stays pure black.
        #expect(atCursor.r > elsewhere.r)
    }

    @Test func selectionHighlightCoversTheSelectedRange() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let queue = device.makeCommandQueue()!
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let renderer = try TerminalRenderer(device: device, font: font)

        let terminal = Terminal(rows: 4, columns: 10)
        let grid = terminal.grid

        let width = Int(renderer.metrics.cellWidth * 10)
        let height = Int(renderer.metrics.cellHeight * 4)
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

        let selection = TerminalSelection(
            start: GridPosition(row: 1, column: 2), end: GridPosition(row: 1, column: 4))

        let commandBuffer = queue.makeCommandBuffer()!
        renderer.render(
            grid: grid, rect: CGRect(x: 0, y: 0, width: width, height: height),
            drawableSize: CGSize(width: width, height: height), cursorVisible: false,
            selection: selection, renderPassDescriptor: pass, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        Self.synchronize(texture, queue: queue)

        let insideX = Int(Float(3) * Float(renderer.metrics.cellWidth) + Float(renderer.metrics.cellWidth) / 2)
        let insideY = Int(Float(1) * Float(renderer.metrics.cellHeight) + Float(renderer.metrics.cellHeight) / 2)
        let outsideX = Int(Float(7) * Float(renderer.metrics.cellWidth) + Float(renderer.metrics.cellWidth) / 2)

        let inside = Self.pixel(of: texture, x: insideX, y: insideY)
        let outside = Self.pixel(of: texture, x: outsideX, y: insideY)
        #expect(inside.b > outside.b, "expected the selection tint inside the range")
    }
}
