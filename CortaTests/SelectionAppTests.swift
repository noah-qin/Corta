import CoreGraphics
import CoreText
import CortaTerminal
import Metal
import Testing

@testable import Corta

/// M3.7, renderer side: the selection's document rows (scrollback rows
/// negative) are translated to viewport rows through the scroll offset and
/// the scrollback's growth since the selection was recorded.
struct SelectionRendererTests {
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

    /// A renderer and a render target sized to a 10x4 grid, or nil when no
    /// Metal device is available.
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
        _ fixture: Fixture, grid: Grid, scrollOffset: Int, selection: TerminalSelection?
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
            cursorVisible: false, selection: selection,
            renderPassDescriptor: pass, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        Self.synchronize(texture, queue: fixture.queue)
        return texture
    }

    /// The centre of a cell in the fixture's texture.
    private static func cellCenter(
        _ fixture: Fixture, column: Int, row: Int
    ) -> (x: Int, y: Int) {
        (
            x: Int((Float(column) + 0.5) * Float(fixture.renderer.metrics.cellWidth)),
            y: Int((Float(row) + 0.5) * Float(fixture.renderer.metrics.cellHeight))
        )
    }

    /// A 4x10 terminal with six two-character lines; the first three have
    /// scrolled into the scrollback. Selected columns (4...8) are blank on
    /// every line, so glyph pixels never confuse the tint check.
    private static func scrolledTerminal() -> Terminal {
        var terminal = Terminal(rows: 4, columns: 10, scrollbackLimit: 100)
        for _ in 0..<6 { terminal.feed(Array("ab\r\n".utf8)) }
        return terminal
    }

    @Test func scrollbackSelectionRendersWhenScrolledIntoView() throws {
        guard let fixture = try Self.fixture() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let terminal = Self.scrolledTerminal()
        let grid = terminal.grid
        let count = grid.scrollback.count
        #expect(count == 3)

        // The oldest history line, blank columns 4-8, recorded against the
        // current scrollback depth.
        let selection = TerminalSelection(
            start: GridPosition(row: -count, column: 4),
            end: GridPosition(row: -count, column: 8),
            baseScrollbackCount: count)

        // Scrolled all the way up, that line is viewport row 0.
        let scrolled = Self.draw(fixture, grid: grid, scrollOffset: count, selection: selection)
        let inside = Self.cellCenter(fixture, column: 6, row: 0)
        let outside = Self.cellCenter(fixture, column: 2, row: 0)
        #expect(
            Self.pixel(of: scrolled, x: inside.x, y: inside.y).b
                > Self.pixel(of: scrolled, x: outside.x, y: outside.y).b,
            "expected the selection tint over the selected scrollback line")

        // On the live screen the same selection is entirely above the
        // viewport and must paint nothing.
        let live = Self.draw(fixture, grid: grid, scrollOffset: 0, selection: selection)
        let tinted = Self.pixel(of: scrolled, x: inside.x, y: inside.y)
        let untinted = Self.pixel(of: live, x: inside.x, y: inside.y)
        #expect(untinted.b < tinted.b, "an offscreen selection must not paint")
    }

    @Test func selectionFollowsItsTextWhenOutputScrolls() throws {
        guard let fixture = try Self.fixture() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        var terminal = Terminal(rows: 4, columns: 10, scrollbackLimit: 100)
        terminal.feed(Array("ab\r\n".utf8))  // row 0
        terminal.feed(Array("cd\r\n".utf8))  // row 1
        let grid1 = terminal.grid

        // Blank columns of the "cd" line, recorded against an empty
        // scrollback.
        let selection = TerminalSelection(
            start: GridPosition(row: 1, column: 4),
            end: GridPosition(row: 1, column: 8),
            baseScrollbackCount: 0)
        #expect(grid1.scrollback.count == 0)

        // Frame 1 populates the renderer's caches, overlay included.
        let before = Self.draw(fixture, grid: grid1, scrollOffset: 0, selection: selection)
        let row1 = Self.cellCenter(fixture, column: 6, row: 1)
        #expect(
            Self.pixel(of: before, x: row1.x, y: row1.y).b > 0,
            "the selection tints the line it was made on")

        // Output pushes "ab" into the scrollback; every row below it moves
        // up one, "cd" included. The grid's lines all change, but the
        // selection value does not — only its base is now stale.
        terminal.feed(Array("ef\r\n".utf8))
        terminal.feed(Array("gh\r\n".utf8))
        let grid2 = terminal.grid
        #expect(grid2.scrollback.count == 1)

        let after = Self.draw(fixture, grid: grid2, scrollOffset: 0, selection: selection)
        let row0 = Self.cellCenter(fixture, column: 6, row: 0)
        #expect(
            Self.pixel(of: after, x: row0.x, y: row0.y).b > 0,
            "the highlight must move up with its text")
        #expect(
            Self.pixel(of: after, x: row1.x, y: row1.y).b == 0,
            "a stale highlight would still sit on the old row")
    }
}

/// M3.7, hit-testing: a view point maps to a document position through the
/// content insets, the grid's bottom anchoring and the scroll offset.
struct SelectionCellMappingTests {
    private static let metrics = CellMetrics(
        font: CTFontCreateWithName("Menlo" as CFString, 14, nil))

    /// A view exactly as tall as the insets plus the grid: no remainder, so
    /// the grid top is the top inset.
    private static func exactHeight(rows: Int) -> CGFloat {
        TerminalLayout.insets.top + TerminalLayout.insets.bottom
            + CGFloat(rows) * metrics.cellHeight
    }

    @Test func pointInsideTheGridMapsToItsCell() {
        let grid = Grid(rows: 30, columns: 120)
        let point = CGPoint(
            x: TerminalLayout.insets.left + 2.5 * Self.metrics.cellWidth,
            y: TerminalLayout.insets.top + 3.5 * Self.metrics.cellHeight)
        let position = ViewController.documentPosition(
            for: point, viewHeight: Self.exactHeight(rows: 30), metrics: Self.metrics,
            grid: grid, scrollOffset: 0)
        #expect(position.row == 3)
        #expect(position.column == 2)
    }

    @Test func theGridIsBottomAnchoredWhenTheViewHasARemainder() {
        let grid = Grid(rows: 30, columns: 120)
        // Half a cell of extra height lands at the top, pushing the grid
        // down: a point just inside row 1 of the exact-height layout is row
        // 0 of this one.
        let point = CGPoint(
            x: TerminalLayout.insets.left + 2.5 * Self.metrics.cellWidth,
            y: TerminalLayout.insets.top + 1.1 * Self.metrics.cellHeight)
        let position = ViewController.documentPosition(
            for: point, viewHeight: Self.exactHeight(rows: 30) + Self.metrics.cellHeight / 2,
            metrics: Self.metrics, grid: grid, scrollOffset: 0)
        #expect(position.row == 0)
    }

    @Test func theScrollOffsetMovesEventsIntoDocumentRows() {
        let grid = Grid(rows: 30, columns: 120)
        let point = CGPoint(
            x: TerminalLayout.insets.left + 1,
            y: TerminalLayout.insets.top + 1)
        let position = ViewController.documentPosition(
            for: point, viewHeight: Self.exactHeight(rows: 30), metrics: Self.metrics,
            grid: grid, scrollOffset: 7)
        #expect(position.row == -7, "viewport row 0 is document row -scrollOffset")
        #expect(position.column == 0)
    }

    @Test func pointsOutsideTheGridClampToTheEdge() {
        let grid = Grid(rows: 30, columns: 120)
        let far = ViewController.documentPosition(
            for: CGPoint(x: 9_999, y: 9_999), viewHeight: Self.exactHeight(rows: 30),
            metrics: Self.metrics, grid: grid, scrollOffset: 0)
        #expect(far.row == 29)
        #expect(far.column == 119)
        let above = ViewController.documentPosition(
            for: CGPoint(x: -50, y: -50), viewHeight: Self.exactHeight(rows: 30),
            metrics: Self.metrics, grid: grid, scrollOffset: 0)
        #expect(above.row == 0)
        #expect(above.column == 0)
    }
}
