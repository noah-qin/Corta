import CoreGraphics
import CoreText
import CortaTerminal
import Metal
import Testing

@testable import Corta

/// D.4: the renderer draws the DECSCUSR cursor style the core tracks
/// (`Grid.cursorStyle`) — block, bar and underline; blinking variants draw
/// steady.
/// `.serialized`: these build a `GlyphAtlas`, which is single-threaded
/// by design — see the type's comment.
@Suite(.serialized) struct CursorStyleRenderTests {
    private static func pixel(of texture: MTLTexture, x: Int, y: Int) -> (
        r: UInt8, g: UInt8, b: UInt8, a: UInt8
    ) {
        var bytes = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return (r: bytes[2], g: bytes[1], b: bytes[0], a: bytes[3])
    }

    private static func synchronize(_ texture: MTLTexture, queue: MTLCommandQueue) {
        guard let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder()
        else { return }
        blit.synchronize(resource: texture)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    /// Renders a 4x10 grid containing "abc" (cursor on row 0, column 3) with
    /// the given DECSCUSR parameter applied, and returns the texture.
    private static func renderWithCursorStyle(
        _ decscusr: String?, queue: MTLCommandQueue
    ) throws -> (texture: MTLTexture, renderer: TerminalRenderer) {
        let device = queue.device
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let renderer = try TerminalRenderer(device: device, font: font, scale: 1)

        var terminal = Terminal(rows: 4, columns: 10)
        terminal.feed(Array("abc".utf8))  // cursor now sits at row 0, column 3
        if let decscusr {
            terminal.feed(Array("\u{1B}[\(decscusr) q".utf8))
        }
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
        synchronize(texture, queue: queue)
        return (texture, renderer)
    }

    @Test func underlineCursorDrawsOnlyAtTheCellBottom() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let queue = device.makeCommandQueue()!
        let (texture, renderer) = try Self.renderWithCursorStyle("4", queue: queue)
        let cellW = Int(renderer.metrics.cellWidth)
        let cellH = Int(renderer.metrics.cellHeight)
        let cellX = 3 * cellW  // cursor column

        let top = Self.pixel(of: texture, x: cellX + cellW / 2, y: cellH / 2)
        let bottom = Self.pixel(of: texture, x: cellX + cellW / 2, y: cellH - 1)
        // The cursor colour is a translucent grey over the black clear colour.
        #expect(top.r < 30, "cell interior must stay background, got \(top)")
        #expect(bottom.r > 60, "bottom stroke must carry the cursor colour, got \(bottom)")
    }

    @Test func barCursorDrawsOnlyAtTheCellLeadingEdge() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let queue = device.makeCommandQueue()!
        let (texture, renderer) = try Self.renderWithCursorStyle("6", queue: queue)
        let cellW = Int(renderer.metrics.cellWidth)
        let cellH = Int(renderer.metrics.cellHeight)
        let cellX = 3 * cellW

        let leading = Self.pixel(of: texture, x: cellX + 1, y: cellH / 2)
        let trailing = Self.pixel(of: texture, x: cellX + cellW - 2, y: cellH / 2)
        #expect(leading.r > 60, "leading stroke must carry the cursor colour, got \(leading)")
        #expect(trailing.r < 30, "cell interior must stay background, got \(trailing)")
    }

    @Test func steadyBlockCursorFillsTheWholeCell() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let queue = device.makeCommandQueue()!
        let (texture, renderer) = try Self.renderWithCursorStyle("2", queue: queue)
        let cellW = Int(renderer.metrics.cellWidth)
        let cellH = Int(renderer.metrics.cellHeight)
        let cellX = 3 * cellW

        let top = Self.pixel(of: texture, x: cellX + cellW / 2, y: 1)
        let bottom = Self.pixel(of: texture, x: cellX + cellW / 2, y: cellH - 1)
        #expect(top.r > 60, "block must cover the cell top, got \(top)")
        #expect(bottom.r > 60, "block must cover the cell bottom, got \(bottom)")
    }

    /// A style change alone — no line touched, cursor unmoved — must still
    /// produce a frame, or the new style never appears on an idle screen.
    @Test func cursorStyleChangeAloneReportsDamage() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let renderer = try TerminalRenderer(device: device, font: font, scale: 1)
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.feed(Array("abc".utf8))
        renderer.updateInstances(
            grid: terminal.grid, scrollOffset: 0, cursorVisible: true, selection: nil)
        #expect(
            !renderer.updateInstances(
                grid: terminal.grid, scrollOffset: 0, cursorVisible: true, selection: nil))

        terminal.feed(Array("\u{1B}[4 q".utf8))  // DECSCUSR: steady underline
        #expect(
            renderer.updateInstances(
                grid: terminal.grid, scrollOffset: 0, cursorVisible: true, selection: nil))
        #expect(renderer.lastRebuiltRowCount == 0)
    }
}
