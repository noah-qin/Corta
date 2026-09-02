import CoreGraphics
import CoreText
import CortaTerminal
import Metal
import simd

/// A single point in the *document*: (row, column), where row ≥ 0 is a
/// live-screen row and row < 0 addresses the scrollback counting backwards
/// from the screen boundary (row -1 is the newest history line). Never a
/// viewport row — scrolling translates, it does not move the selection.
nonisolated struct GridPosition: Equatable {
    var row: Int
    var column: Int
}

/// An inclusive text selection, `start` to `end` in document order.
nonisolated struct TerminalSelection {
    var start: GridPosition
    var end: GridPosition
    /// The scrollback depth the rows were recorded against. Output since
    /// then has pushed `grid.scrollback.count - baseScrollbackCount` lines
    /// into history, shifting every stored row by that much; the renderer
    /// applies the shift when translating to viewport rows. (Exact while
    /// the ring is not yet full; once it is, pushes evict without growing
    /// the count and the shift undercounts — the selection then stays put
    /// rather than tracking text that flooded past.)
    var baseScrollbackCount: Int = 0
}

/// Turns a `Grid` snapshot into instanced quads and draws it into a given
/// rectangle — two draw calls (background, glyphs).
///
/// **Damage tracking** (`PERFORMANCE.md` §3, roadmap M4.1): the core exposes
/// no version or damage signal (`TerminalSession.snapshot()` is a plain COW
/// copy), so damage is computed here instead — each frame's snapshot lines
/// are compared against the lines the cached instances were built from, at
/// line granularity, and only the damaged rows' instances are rebuilt and
/// spliced into the cached arrays. `Line` is a value type over
/// `ContiguousArray<Cell>`, so an unchanged row typically shares storage with
/// the snapshot and compares by a cheap `memcmp`. A fully static frame
/// rebuilds nothing and reports "no damage", which is what lets the shell
/// skip the frame entirely (no drawable, no command buffer, ~0% idle CPU).
///
/// Cursor and selection are extra background-pass quads, not a third
/// pipeline: a block cursor and a selection highlight are colour under the
/// glyph, exactly like a cell's own background.
nonisolated final class TerminalRenderer {
    let quadRenderer: QuadRenderer
    let glyphAtlas: GlyphAtlas
    var metrics: CellMetrics

    /// Alpha for the cursor block and selection highlight, over the cell's
    /// own background.
    private static let cursorColor = SIMD4<Float>(0.6, 0.6, 0.6, 0.6)
    private static let selectionColor = SIMD4<Float>(0.25, 0.45, 0.85, 0.4)

    // MARK: - Damage-tracked instance cache

    /// The line each viewport row's cached instances were built from.
    private var cachedLines: [Line] = []
    /// How many instances each viewport row contributes to the cached arrays;
    /// a row's slice starts at the sum of the counts before it.
    private var backgroundCounts: [Int] = []
    private var glyphCounts: [Int] = []
    private var cachedBackground: [QuadInstance] = []
    private var cachedGlyphs: [QuadInstance] = []
    /// Selection and cursor quads live at the tail of `cachedBackground`.
    private var overlayCount = 0
    /// What the cache was built against; a mismatch forces a full rebuild.
    private var cachedColumns = 0
    private var cachedOffset = -1
    private var cachedScrollbackCount = -1
    private var cachedCursor: Cursor?
    private var cachedCursorVisible = false
    private var cachedSelection: TerminalSelection?
    private var needsFullRebuild = true

    /// Scratch for one row's rebuild, reused across rows and frames so a
    /// damaged row allocates nothing (`PERFORMANCE.md` §3).
    private var rowBackground: [QuadInstance] = []
    private var rowGlyphs: [QuadInstance] = []
    private var overlayScratch: [QuadInstance] = []

    /// Test hook: how many viewport rows the last `updateInstances` rebuilt.
    private(set) var lastRebuiltRowCount = 0

    /// Cell geometry in points — what the window, the grid size and mouse
    /// coordinates are expressed in.
    let pointMetrics: CellMetrics
    /// The backing scale this renderer's atlas was rasterised for.
    let scale: CGFloat

    /// - Parameter scale: the display's backing scale factor. Glyphs are
    ///   rasterised at `font size * scale` so they are sharp at device
    ///   resolution, and `metrics` is in pixels to match the shader, whose
    ///   coordinate space is the drawable — pixels, not points. Rasterising
    ///   at 1x and laying out in point units on a 2x display is what made the
    ///   text render at half size and look soft.
    init(device: MTLDevice, font: CTFont, scale: CGFloat) throws {
        let atlasFont = CTFontCreateCopyWithAttributes(
            font, CTFontGetSize(font) * scale, nil, nil)
        self.quadRenderer = try QuadRenderer(device: device)
        self.glyphAtlas = GlyphAtlas(device: device, font: atlasFont)
        self.pointMetrics = CellMetrics(font: font)
        self.metrics = CellMetrics(font: font).scaled(by: scale)
        self.scale = scale
    }

    /// Marks every row damaged, so the next `updateInstances` rebuilds the
    /// whole buffer — used by the frame-CPU baseline to keep measuring the
    /// worst case now that steady-state frames rebuild nothing.
    func invalidate() {
        needsFullRebuild = true
    }

    /// Compares `grid` against the cache at line granularity and rebuilds
    /// only the damaged rows' instances (a changed scroll offset or grid size
    /// shifts every on-screen position, so those are a full rebuild). Returns
    /// whether anything changed — `false` means the cached instances still
    /// match and the caller can skip the frame entirely.
    @discardableResult
    func updateInstances(
        grid: Grid, scrollOffset: Int, cursorVisible: Bool, selection: TerminalSelection?
    ) -> Bool {
        let offset = min(max(0, scrollOffset), grid.scrollback.count)
        let fullRebuild =
            needsFullRebuild
            || cachedLines.count != grid.rows
            || cachedColumns != grid.columns
            || cachedOffset != offset
            // Scrolled into history, the viewport is a window over a ring
            // buffer that output keeps shifting — every row moves.
            || (offset > 0 && cachedScrollbackCount != grid.scrollback.count)

        var changed = fullRebuild
        if fullRebuild {
            rebuildAllRows(grid: grid, offset: offset)
        } else {
            changed = rebuildDamagedRows(grid: grid, offset: offset)
        }

        if fullRebuild || !Self.selectionsEqual(cachedSelection, selection)
            || grid.cursor != cachedCursor || cursorVisible != cachedCursorVisible
            // Output that scrolled lines into history shifts the selection's
            // viewport rows without the selection itself changing.
            || (selection != nil && cachedScrollbackCount != grid.scrollback.count)
        {
            rebuildOverlay(grid: grid, cursorVisible: cursorVisible, selection: selection, offset: offset)
            changed = true
        }

        cachedColumns = grid.columns
        cachedOffset = offset
        cachedScrollbackCount = grid.scrollback.count
        cachedCursor = grid.cursor
        cachedCursorVisible = cursorVisible
        cachedSelection = selection
        needsFullRebuild = false
        return changed
    }

    /// Draws `grid` into `rect` of `renderPassDescriptor`. `cursorVisible`
    /// lets the shell blink the cursor without touching the grid.
    /// - Parameter scrollOffset: lines of scrollback above the screen to
    ///   show instead of it, clamped to what history actually holds. `0` is
    ///   the live screen (`M1.20`).
    func render(
        grid: Grid,
        scrollOffset: Int = 0,
        rect: CGRect,
        drawableSize: CGSize,
        cursorVisible: Bool,
        selection: TerminalSelection?,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        updateInstances(
            grid: grid, scrollOffset: scrollOffset, cursorVisible: cursorVisible,
            selection: selection)

        quadRenderer.drawSolidQuads(
            cachedBackground, rect: rect, drawableSize: drawableSize,
            renderPassDescriptor: renderPassDescriptor, commandBuffer: commandBuffer)
        // The glyph pass must never clear: whatever load action the caller
        // wanted has already happened for the background pass above, and a
        // second clear here would erase every background and cursor quad
        // just drawn. `MTLRenderPassDescriptor` is a reference type, so this
        // mutation is local to the two draws in this call.
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        quadRenderer.drawGlyphQuads(
            cachedGlyphs, atlas: glyphAtlas.texture, rect: rect, drawableSize: drawableSize,
            renderPassDescriptor: renderPassDescriptor, commandBuffer: commandBuffer)
    }

    /// Full rebuild: every row's instances, straight into the cached arrays.
    private func rebuildAllRows(grid: Grid, offset: Int) {
        cachedBackground.removeAll(keepingCapacity: true)
        cachedGlyphs.removeAll(keepingCapacity: true)
        backgroundCounts.removeAll(keepingCapacity: true)
        glyphCounts.removeAll(keepingCapacity: true)
        cachedLines.removeAll(keepingCapacity: true)
        cachedBackground.reserveCapacity(grid.rows * grid.columns / 4 + 2)
        cachedGlyphs.reserveCapacity(grid.rows * grid.columns / 2)
        for row in 0..<grid.rows {
            let line = Self.visibleLine(grid: grid, row: row, offset: offset)
            let backgroundStart = cachedBackground.count
            let glyphStart = cachedGlyphs.count
            appendRowInstances(line: line, row: row, background: &cachedBackground, glyphs: &cachedGlyphs)
            backgroundCounts.append(cachedBackground.count - backgroundStart)
            glyphCounts.append(cachedGlyphs.count - glyphStart)
            cachedLines.append(line)
        }
        overlayCount = 0
        lastRebuiltRowCount = grid.rows
    }

    /// Line-granular damage: rebuild only the rows whose line changed and
    /// splice their instances in place. Walking rows in order keeps each
    /// splice point correct, because every later row sits after it.
    private func rebuildDamagedRows(grid: Grid, offset: Int) -> Bool {
        var changed = false
        var rebuilt = 0
        var backgroundStart = 0
        var glyphStart = 0
        for row in 0..<grid.rows {
            let line = Self.visibleLine(grid: grid, row: row, offset: offset)
            if line != cachedLines[row] {
                rowBackground.removeAll(keepingCapacity: true)
                rowGlyphs.removeAll(keepingCapacity: true)
                appendRowInstances(line: line, row: row, background: &rowBackground, glyphs: &rowGlyphs)
                cachedBackground.replaceSubrange(
                    backgroundStart..<(backgroundStart + backgroundCounts[row]), with: rowBackground)
                cachedGlyphs.replaceSubrange(
                    glyphStart..<(glyphStart + glyphCounts[row]), with: rowGlyphs)
                backgroundCounts[row] = rowBackground.count
                glyphCounts[row] = rowGlyphs.count
                cachedLines[row] = line
                changed = true
                rebuilt += 1
            }
            backgroundStart += backgroundCounts[row]
            glyphStart += glyphCounts[row]
        }
        lastRebuiltRowCount = rebuilt
        return changed
    }

    /// Selection and cursor quads, rebuilt when either changes and spliced
    /// into the tail of `cachedBackground`, after every row's slice.
    private func rebuildOverlay(grid: Grid, cursorVisible: Bool, selection: TerminalSelection?, offset: Int) {
        let cellWidth = Float(metrics.cellWidth)
        let cellHeight = Float(metrics.cellHeight)
        overlayScratch.removeAll(keepingCapacity: true)
        if let selection {
            overlayScratch.append(
                contentsOf: selectionQuads(
                    selection, grid: grid, offset: offset, cellWidth: cellWidth, cellHeight: cellHeight))
        }
        if cursorVisible {
            let origin = SIMD2<Float>(
                Float(grid.cursor.column) * cellWidth, Float(grid.cursor.row) * cellHeight)
            overlayScratch.append(
                QuadInstance(origin: origin, size: .init(cellWidth, cellHeight), color: Self.cursorColor))
        }
        let end = cachedBackground.count
        cachedBackground.replaceSubrange((end - overlayCount)..<end, with: overlayScratch)
        overlayCount = overlayScratch.count
    }

    /// Every instance one viewport row contributes — the per-cell loop that
    /// used to run for the whole screen every frame, now run only for rows
    /// whose line actually changed.
    private func appendRowInstances(
        line: Line, row: Int, background: inout [QuadInstance], glyphs: inout [QuadInstance]
    ) {
        let cellWidth = Float(metrics.cellWidth)
        let cellHeight = Float(metrics.cellHeight)
        let baseline = Float(metrics.baselineOffset)
        for column in 0..<line.count {
            let cell = line[column]
            let reversed = cell.attributes.contains(.reverse)
            let fg = TerminalColorPalette.resolveForeground(reversed ? cell.background : cell.foreground)
            let bg = TerminalColorPalette.resolveBackground(reversed ? cell.foreground : cell.background)

            let origin = SIMD2<Float>(Float(column) * cellWidth, Float(row) * cellHeight)
            if !(reversed ? cell.foreground : cell.background).isDefault || reversed {
                background.append(
                    QuadInstance(origin: origin, size: .init(cellWidth, cellHeight), color: bg))
            }

            // A wide pair's spacer holds a space scalar and draws nothing;
            // the flag check keeps that true even if the scalar ever
            // changes. Double-width *glyph* drawing is beyond M2.1 — the
            // lead's glyph is drawn into a single cell for now.
            guard !cell.attributes.contains(.invisible),
                !cell.attributes.contains(.wideSpacer), cell.scalar != 0x20,
                let scalar = Unicode.Scalar(cell.scalar)
            else { continue }
            let bold = cell.attributes.contains(.bold)
            let info =
                scalar.isASCII
                ? glyphAtlas.glyph(forASCII: cell.scalar, bold: bold)
                : glyphAtlas.glyph(shaping: cell.scalar, bold: bold)
            guard let info, info.size != .zero else { continue }

            let glyphOrigin = SIMD2<Float>(
                origin.x + info.bearing.x,
                origin.y + baseline - info.bearing.y - info.size.y
            )
            glyphs.append(
                QuadInstance(origin: glyphOrigin, size: info.size, color: fg, uvRect: info.uvRect))
        }
    }

    private static func selectionsEqual(_ a: TerminalSelection?, _ b: TerminalSelection?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?):
            return a.start == b.start && a.end == b.end
                && a.baseScrollbackCount == b.baseScrollbackCount
        default: return false
        }
    }

    /// The line shown at viewport row `row` when scrolled `offset` lines
    /// into history. `offset == 0` is just `grid.line(row)`; a positive
    /// offset slides the whole screen's worth of rows up through
    /// `scrollback`, oldest line first, exactly as if the ring buffer and
    /// the live screen were one contiguous array.
    private static func visibleLine(grid: Grid, row: Int, offset: Int) -> Line {
        guard offset > 0 else { return grid.line(row) }
        let combinedIndex = grid.scrollback.count + row - offset
        if combinedIndex < grid.scrollback.count {
            return grid.scrollback[combinedIndex]
        }
        return grid.line(combinedIndex - grid.scrollback.count)
    }

    /// The selection's quads in viewport rows. The selection is stored in
    /// document rows (negative = scrollback, see `GridPosition`), recorded
    /// against a scrollback of `baseScrollbackCount` lines; two shifts map
    /// them onto what is on screen now: `growth` for output that pushed
    /// lines into history since, and `offset` for the user's own scrolling.
    /// Rows outside the viewport produce no quads.
    private func selectionQuads(
        _ selection: TerminalSelection, grid: Grid, offset: Int, cellWidth: Float, cellHeight: Float
    ) -> [QuadInstance] {
        guard selection.start.row <= selection.end.row else { return [] }
        let growth = max(0, grid.scrollback.count - selection.baseScrollbackCount)
        let firstRow = selection.start.row - growth + offset
        let lastRow = selection.end.row - growth + offset
        guard lastRow >= 0, firstRow < grid.rows else { return [] }
        var quads: [QuadInstance] = []
        for row in max(0, firstRow)...min(grid.rows - 1, lastRow) {
            let startColumn =
                row == firstRow ? min(max(0, selection.start.column), grid.columns) : 0
            let endColumn =
                row == lastRow ? min(max(0, selection.end.column) + 1, grid.columns) : grid.columns
            guard endColumn > startColumn else { continue }
            quads.append(
                QuadInstance(
                    origin: .init(Float(startColumn) * cellWidth, Float(row) * cellHeight),
                    size: .init(Float(endColumn - startColumn) * cellWidth, cellHeight),
                    color: Self.selectionColor))
        }
        return quads
    }
}
