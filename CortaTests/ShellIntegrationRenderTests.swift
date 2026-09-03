import CoreGraphics
import CoreText
import CortaTerminal
import Metal
import Testing

@testable import Corta

/// Renderer side of the shell-integration marks (M7.2), the hovered-link
/// underline (M7.9) and the missing-glyph placeholder.
///
/// `.serialized`: these build a `GlyphAtlas`, which is single-threaded by
/// design — see that type's comment.
@Suite(.serialized) struct ShellIntegrationRenderTests {
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

    private static func draw(
        _ fixture: Fixture, grid: Grid, hoveredLink: TerminalSelection? = nil
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
            grid: grid, scrollOffset: 0,
            rect: CGRect(x: 0, y: 0, width: fixture.width, height: fixture.height),
            drawableSize: CGSize(width: fixture.width, height: fixture.height),
            cursorVisible: false, selection: nil, hoveredLink: hoveredLink,
            renderPassDescriptor: pass, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        synchronize(texture, queue: fixture.queue)
        return texture
    }

    /// A prompt row gets a rule down its left edge, coloured by how the
    /// command ended — green for success, red for failure. Without it there
    /// is no way to see which of the last twenty commands failed.
    @Test func promptMarksPaintTheirStatusColour() throws {
        guard let fixture = try Self.fixture() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        var grid = Grid(rows: 4, columns: 10)
        grid.setMark(.promptSucceeded, atAbsoluteRow: grid.absoluteRow(ofScreenRow: 1))
        grid.setMark(.promptFailed, atAbsoluteRow: grid.absoluteRow(ofScreenRow: 2))
        let texture = Self.draw(fixture, grid: grid)

        let rowHeight = Int(fixture.renderer.metrics.cellHeight)
        let succeeded = Self.pixel(of: texture, x: 0, y: rowHeight + rowHeight / 2)
        let failed = Self.pixel(of: texture, x: 0, y: 2 * rowHeight + rowHeight / 2)
        let unmarked = Self.pixel(of: texture, x: 0, y: rowHeight / 2)

        #expect(succeeded.g > succeeded.r)
        #expect(failed.r > failed.g)
        #expect(unmarked.r == 0 && unmarked.g == 0 && unmarked.b == 0)
    }

    /// The mark is one rule at the left edge, not a wash over the row: text
    /// has to stay readable.
    @Test func aMarkDoesNotTintTheWholeRow() throws {
        guard let fixture = try Self.fixture() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        var grid = Grid(rows: 4, columns: 10)
        grid.setMark(.promptFailed, atAbsoluteRow: grid.absoluteRow(ofScreenRow: 1))
        let texture = Self.draw(fixture, grid: grid)
        let rowHeight = Int(fixture.renderer.metrics.cellHeight)
        let middle = Self.pixel(
            of: texture, x: fixture.width / 2, y: rowHeight + rowHeight / 2)
        #expect(middle.r == 0 && middle.g == 0 && middle.b == 0)
    }

    /// A hovered link underlines, so the target is visible before the click
    /// that opens it.
    @Test func aHoveredLinkIsUnderlined() throws {
        guard let fixture = try Self.fixture() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let grid = Grid(rows: 4, columns: 10)
        let link = TerminalSelection(
            start: GridPosition(row: 1, column: 2), end: GridPosition(row: 1, column: 6))

        let plain = Self.draw(fixture, grid: grid)
        let rowHeight = Int(fixture.renderer.metrics.cellHeight)
        let cellWidth = Int(fixture.renderer.metrics.cellWidth)
        // The rule sits a hair above the row's bottom edge; scan the last few
        // pixel rows rather than pinning the exact one, which is a function
        // of the backing scale.
        let x = 4 * cellWidth
        let rows = ((2 * rowHeight - 4)..<(2 * rowHeight))
        func bluest(_ texture: MTLTexture, x: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            rows.map { Self.pixel(of: texture, x: x, y: $0) }.max { $0.b < $1.b }!
        }
        #expect(bluest(plain, x: x).b == 0)

        fixture.renderer.invalidate()
        let hovered = Self.draw(fixture, grid: grid, hoveredLink: link)
        let underline = bluest(hovered, x: x)
        // The rule is blue: (0.45, 0.7, 1.0).
        #expect(underline.b > underline.r)
        #expect(underline.b > 100)
        // And only under the link, not across the whole row.
        #expect(bluest(hovered, x: 9 * cellWidth).b == 0)
    }
}
