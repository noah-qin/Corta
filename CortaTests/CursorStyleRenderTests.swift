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
@Suite(.serialized, .metalSerialized) struct CursorStyleRenderTests {
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
    /// the given DECSCUSR parameter applied, and returns the texture. The
    /// cursor is painted in `variant`'s cursor colour — the live palette is
    /// whatever the test host's appearance resolved, so it is pinned here
    /// for the render and put back afterwards.
    private static func renderWithCursorStyle(
        _ decscusr: String?, queue: MTLCommandQueue, variant: Theme.Variant = Theme.corta.dark
    ) throws -> (texture: MTLTexture, renderer: TerminalRenderer) {
        let live = TerminalColorPalette.activeVariant
        TerminalColorPalette.apply(variant)
        defer { TerminalColorPalette.apply(live) }
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
        let texture = MetalRenderTarget.make(
            device: device, width: width, height: height)

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
        // The default dark theme's light cursor over the black clear colour.
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

    /// `theme.<name>.<variant>.cursor` is the colour the cursor is painted
    /// in, for every style — the key was documented and parsed before it
    /// reached the renderer, which drew a fixed grey regardless.
    @Test func cursorIsPaintedInTheThemeCursorColour() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let queue = device.makeCommandQueue()!
        var themed = Theme.corta.dark
        themed.cursor = SIMD4<Float>(0, 0, 1, 1)  // pure blue: unmistakable

        for (decscusr, sample) in [
            ("2", "block"), ("4", "underline"), ("6", "bar"),
        ] {
            let (texture, renderer) = try Self.renderWithCursorStyle(
                decscusr, queue: queue, variant: themed)
            let cellW = Int(renderer.metrics.cellWidth)
            let cellH = Int(renderer.metrics.cellHeight)
            let cellX = 3 * cellW
            // Each style's own stroke: the block anywhere, the underline at
            // the bottom edge, the bar at the leading edge.
            let point: (x: Int, y: Int) =
                switch decscusr {
                case "4": (cellX + cellW / 2, cellH - 1)
                case "6": (cellX + 1, cellH / 2)
                default: (cellX + cellW / 2, cellH / 2)
                }
            let pixel = Self.pixel(of: texture, x: point.x, y: point.y)
            #expect(pixel.b > 100, "\(sample) cursor must carry the theme colour, got \(pixel)")
            #expect(pixel.r < 30 && pixel.g < 30, "\(sample) cursor must not keep the old grey, got \(pixel)")
        }
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
