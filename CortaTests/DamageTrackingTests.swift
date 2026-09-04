import CoreGraphics
import CoreText
import CortaTerminal
import Metal
import Testing

@testable import Corta

/// Damage tracking (M4.1 pulled into M2, `PERFORMANCE.md` §3): the instance
/// buffer is rebuilt only for rows whose line actually changed, and a fully
/// static screen reports no damage at all — which is what lets the shell skip
/// the frame and idle at ~0% CPU.
/// `.serialized`: these build a `GlyphAtlas`, which is single-threaded
/// by design — see the type's comment.
@Suite(.serialized) struct DamageTrackingTests {
    private static func makeRenderer() -> TerminalRenderer? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        return try? TerminalRenderer(device: device, font: font, scale: 1)
    }

    @Test func staticScreenReportsNoDamageAfterFirstBuild() throws {
        let renderer = try #require(Self.makeRenderer())
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.feed(Array("abc".utf8))

        // First build covers every row.
        #expect(renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: true, selection: nil))
        #expect(renderer.lastRebuiltRowCount == 4)

        // A snapshot of the unchanged grid damages nothing.
        #expect(!renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: true, selection: nil))
        #expect(renderer.lastRebuiltRowCount == 0)
    }

    @Test func oneChangedRowRebuildsOnlyThatRow() throws {
        let renderer = try #require(Self.makeRenderer())
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.feed(Array("aaaa\r\nbbbb\r\ncccc".utf8))
        renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: true, selection: nil)

        // Overwrite row 1 only (CUP to row 2, column 1, then write).
        terminal.feed(Array("\u{1B}[2;1HXX".utf8))
        #expect(renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: true, selection: nil))
        #expect(renderer.lastRebuiltRowCount == 1)

        // And it settles again.
        #expect(!renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: true, selection: nil))
        #expect(renderer.lastRebuiltRowCount == 0)
    }

    @Test func cursorMotionAloneRebuildsNoRowsButStillReportsDamage() throws {
        let renderer = try #require(Self.makeRenderer())
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.feed(Array("abc".utf8))
        renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: true, selection: nil)

        // CUP moves the cursor without touching any line: no rows rebuild,
        // but the frame must still be drawn (the cursor quad moved).
        terminal.feed(Array("\u{1B}[3;5H".utf8))
        #expect(renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: true, selection: nil))
        #expect(renderer.lastRebuiltRowCount == 0)
    }

    @Test func hiddenCursorChangesNothing() throws {
        let renderer = try #require(Self.makeRenderer())
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.feed(Array("abc".utf8))
        renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: false, selection: nil)
        #expect(!renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: false, selection: nil))
    }

    @Test func partialRebuildKeepsOtherRowsOnScreen() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let queue = device.makeCommandQueue()!
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let renderer = try TerminalRenderer(device: device, font: font, scale: 1)

        var terminal = Terminal(rows: 4, columns: 10)
        terminal.feed(Array("aaaa\r\nbbbb".utf8))

        let width = Int(renderer.metrics.cellWidth * 10)
        let height = Int(renderer.metrics.cellHeight * 4)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: QuadRenderer.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        let texture = device.makeTexture(descriptor: descriptor)!

        func draw() {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            pass.colorAttachments[0].storeAction = .store
            let commandBuffer = queue.makeCommandBuffer()!
            renderer.render(
                grid: terminal.grid, rect: CGRect(x: 0, y: 0, width: width, height: height),
                drawableSize: CGSize(width: width, height: height), cursorVisible: false,
                selection: nil, renderPassDescriptor: pass, commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }

        // Whether any pixel in a cell is non-black (a glyph was drawn there).
        func cellHasInk(row: Int, column: Int) -> Bool {
            let cellW = Int(renderer.metrics.cellWidth)
            let cellH = Int(renderer.metrics.cellHeight)
            var bytes = [UInt8](repeating: 0, count: cellW * cellH * 4)
            texture.getBytes(
                &bytes, bytesPerRow: cellW * 4,
                from: MTLRegionMake2D(column * cellW, row * cellH, cellW, cellH), mipmapLevel: 0)
            return bytes.contains { $0 != 0 }
        }

        draw()
        #expect(cellHasInk(row: 0, column: 0))  // 'a'
        #expect(cellHasInk(row: 1, column: 0))  // 'b'

        // Damage row 0 only; the splice must keep row 1's instances.
        terminal.feed(Array("\u{1B}[1;1HZ".utf8))
        #expect(renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: false, selection: nil))
        #expect(renderer.lastRebuiltRowCount == 1)
        draw()
        #expect(cellHasInk(row: 0, column: 0))  // 'Z' replaced 'a'
        #expect(cellHasInk(row: 1, column: 0))  // 'b' survived the splice
    }

    @Test func scrollOffsetChangeIsAFullRebuild() throws {
        let renderer = try #require(Self.makeRenderer())
        var terminal = Terminal(rows: 4, columns: 10, scrollbackLimit: 100)
        for i in 0..<10 { terminal.feed(Array("row\(i)\r\n".utf8)) }
        let grid = terminal.grid
        #expect(grid.scrollback.count > 0)

        renderer.updateInstances(grid: grid, scrollOffset: 0, cursorVisible: false, selection: nil)
        #expect(renderer.updateInstances(grid: grid, scrollOffset: 1, cursorVisible: false, selection: nil))
        #expect(renderer.lastRebuiltRowCount == 4)
    }

    // MARK: - M9: scroll shift

    /// A whole-screen scroll (M9) only rebuilds the newly exposed row —
    /// the survivors' instances are shifted in place, not rebuilt — so
    /// `lastRebuiltRowCount` after a one-line scroll is 1, not the whole
    /// screen, and the content each row shows afterward is still correct.
    @Test func oneLineScrollRebuildsOnlyTheExposedRow() throws {
        let renderer = try #require(Self.makeRenderer())
        var terminal = Terminal(rows: 4, columns: 10, scrollbackLimit: 100)
        terminal.feed(Array("aaaa\r\nbbbb\r\ncccc\r\ndddd".utf8))
        renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: false, selection: nil)

        // One newline past the bottom margin scrolls the whole screen up by
        // exactly one row and pushes row 0 ("aaaa") into scrollback.
        terminal.feed(Array("\r\neeee".utf8))
        #expect(renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: false, selection: nil))
        #expect(renderer.lastRebuiltRowCount == 1)

        // And it settles: the same scrolled screen reports no further damage.
        #expect(!renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: false, selection: nil))
    }

    /// A batch with several newlines scrolls more than one row in a single
    /// frame — the shift has to account for the *cumulative* amount since
    /// the cache was last synced, not just one `rotateUp` call.
    @Test func multiLineScrollInOneBatchShiftsByTheWholeAmount() throws {
        let renderer = try #require(Self.makeRenderer())
        var terminal = Terminal(rows: 4, columns: 10, scrollbackLimit: 100)
        terminal.feed(Array("aaaa\r\nbbbb\r\ncccc\r\ndddd".utf8))
        renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: false, selection: nil)

        // Three newlines in one feed, never diffed in between — three rows
        // scroll off before the renderer ever sees an intermediate state.
        terminal.feed(Array("\r\neeee\r\nffff\r\ngggg".utf8))
        #expect(renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: false, selection: nil))
        #expect(renderer.lastRebuiltRowCount == 3)
        #expect(!renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: false, selection: nil))
    }

    /// A scroll followed, in the same batch, by an edit to a row that
    /// survived the scroll (not the newly exposed one) — the shift and the
    /// ordinary per-row damage check must both apply; the edited row is not
    /// allowed to slip through just because it was also shifted.
    @Test func editToASurvivingRowIsNotMaskedByTheShift() throws {
        let renderer = try #require(Self.makeRenderer())
        var terminal = Terminal(rows: 4, columns: 10, scrollbackLimit: 100)
        terminal.feed(Array("aaaa\r\nbbbb\r\ncccc\r\ndddd".utf8))
        renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: false, selection: nil)

        // Scroll one row, then jump up to the row that is now row 0
        // (old row 1, "bbbb") and overwrite it.
        terminal.feed(Array("\r\neeee\u{1B}[1;1HZZZZ".utf8))
        #expect(renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: false, selection: nil))
        // The exposed row (row 3) and the independently edited row (row 0):
        // two rebuilt rows, not one, and not the whole screen.
        #expect(renderer.lastRebuiltRowCount == 2)
    }

    /// A scroll of the whole screen's height or more leaves nothing to
    /// shift — every row differs from the cache regardless — and must not
    /// crash trying to shift more rows than the cache holds.
    @Test func scrollPastAFullScreenDoesNotCrash() throws {
        let renderer = try #require(Self.makeRenderer())
        var terminal = Terminal(rows: 4, columns: 10, scrollbackLimit: 100)
        terminal.feed(Array("aaaa\r\nbbbb\r\ncccc\r\ndddd".utf8))
        renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: false, selection: nil)

        for i in 0..<10 { terminal.feed(Array("row\(i)\r\n".utf8)) }
        #expect(renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: false, selection: nil))
        #expect(renderer.lastRebuiltRowCount == 4)
    }

    /// Entering and leaving the alternate screen swaps in a wholesale
    /// different `ScreenLines` with its own revision numbering
    /// (`ScreenLines.generation`) — a coincidental match with the cache's
    /// low early revision numbers must not be mistaken for "unchanged".
    @Test func alternateScreenSwapForcesAFullRebuildEvenWithMatchingDimensions() throws {
        let renderer = try #require(Self.makeRenderer())
        var terminal = Terminal(rows: 4, columns: 10, scrollbackLimit: 100)
        terminal.feed(Array("aaaa".utf8))
        renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: false, selection: nil)

        terminal.feed(Array("\u{1B}[?1049h".utf8))  // enter alternate screen
        #expect(renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: false, selection: nil))
        #expect(renderer.lastRebuiltRowCount == 4)

        terminal.feed(Array("bbbb".utf8))
        renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: false, selection: nil)

        terminal.feed(Array("\u{1B}[?1049l".utf8))  // exit alternate screen
        #expect(renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: false, selection: nil))
        #expect(renderer.lastRebuiltRowCount == 4)
    }
}
