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
nonisolated struct TerminalSelection: Equatable {
    var start: GridPosition
    var end: GridPosition
    /// `Scrollback.totalPushed` when the rows were recorded. Output since
    /// then has pushed `grid.scrollback.totalPushed - baseScrollbackTotal`
    /// lines into history, shifting every stored row by that much; the
    /// renderer applies the shift when translating to viewport rows.
    ///
    /// The monotonic counter rather than `scrollback.count` (M6.10): the
    /// count saturates at the ring's limit, so a flood past capacity evicted
    /// rows without appearing to grow anything, and the highlight drifted
    /// onto whatever text arrived underneath it.
    var baseScrollbackTotal: Int = 0
}

/// Turns a `Grid` snapshot into instanced quads and draws it into a given
/// rectangle — two draw calls (background, glyphs), plus a third for color
/// emoji when a frame contains any (see `cachedColorGlyphs`).
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
/// pipeline: a cursor (block, bar or underline — `Grid.cursorStyle`,
/// blinking variants drawn steady) and a selection highlight are colour
/// under the glyph, exactly like a cell's own background.
nonisolated final class TerminalRenderer {
    let quadRenderer: QuadRenderer
    let glyphAtlas: GlyphAtlas
    private(set) var metrics: CellMetrics

    /// Alpha for the cursor block and selection highlight, over the cell's
    /// own background.
    private static let cursorColor = SIMD4<Float>(0.6, 0.6, 0.6, 0.6)
    private static let selectionColor = SIMD4<Float>(0.25, 0.45, 0.85, 0.4)
    /// M4.4: every search match highlights; the current one differently.
    private static let searchMatchColor = SIMD4<Float>(0.85, 0.75, 0.2, 0.35)
    private static let currentSearchMatchColor = SIMD4<Float>(0.95, 0.55, 0.15, 0.6)
    /// M7.9 — the underline under a hovered link.
    private static let linkUnderlineColor = SIMD4<Float>(0.45, 0.7, 1.0, 0.95)

    // MARK: - Damage-tracked instance cache

    /// The line each viewport row's cached instances were built from.
    private var cachedLines: [Line] = []
    /// How many instances each viewport row contributes to the cached arrays;
    /// a row's slice starts at the sum of the counts before it.
    private var backgroundCounts: [Int] = []
    private var glyphCounts: [Int] = []
    private var colorGlyphCounts: [Int] = []
    private var cachedBackground: [QuadInstance] = []
    private var cachedGlyphs: [QuadInstance] = []
    /// Color-emoji quads, sampled from the atlas's RGBA texture and drawn in
    /// their own pass after the tinted glyphs — the coverage pipeline would
    /// reduce an emoji bitmap to a monochrome silhouette.
    private var cachedColorGlyphs: [QuadInstance] = []
    /// Selection and cursor quads live at the tail of `cachedBackground`.
    private var overlayCount = 0
    /// What the cache was built against; a mismatch forces a full rebuild.
    private var cachedColumns = 0
    private var cachedOffset = -1
    private var cachedScrollbackCount = -1
    private var cachedCursor: Cursor?
    private var cachedCursorStyle: CursorStyle?
    private var cachedCursorVisible = false
    private var cachedSelection: TerminalSelection?
    /// M4.4 search highlights, in document rows exactly like `TerminalSelection`
    /// — recomputed fresh from the current grid whenever the query or the
    /// grid changes, so unlike a selection there is no growth to track.
    private var cachedSearchMatches: [TerminalSelection] = []
    private var cachedCurrentSearchMatchIndex: Int?
    /// The link the pointer is over (M7.9), underlined so the target is
    /// visible before a click can open it.
    private var cachedHoveredLink: TerminalSelection?
    private var needsFullRebuild = true

    /// Scratch for one row's rebuild, reused across rows and frames so a
    /// damaged row allocates nothing (`PERFORMANCE.md` §3).
    private var rowBackground: [QuadInstance] = []
    private var rowGlyphs: [QuadInstance] = []
    private var rowColorGlyphs: [QuadInstance] = []
    private var overlayScratch: [QuadInstance] = []

    /// Underline, strikethrough and invisible together — the attributes that
    /// make a cell need more than a glyph. One mask test rejects the
    /// overwhelming majority of cells, which carry none of them.
    private static let ruleAttributeMask: UInt16 =
        CellAttributes.underline.rawValue | CellAttributes.strikethrough.rawValue
        | CellAttributes.invisible.rawValue

    /// How much foreground alpha SGR 2 (dim) keeps. Chosen the way every
    /// other terminal does it — visibly secondary, still readable on both a
    /// dark and a light background. Blending to zero would make dim text
    /// invisible, which is `invisible`'s job, not this one's.
    private static let dimAlpha: Float = 0.55

    /// Test hook: how many viewport rows the last `updateInstances` rebuilt.
    private(set) var lastRebuiltRowCount = 0

    /// Cell geometry in points — what the window, the grid size and mouse
    /// coordinates are expressed in.
    private(set) var pointMetrics: CellMetrics
    /// The backing scale this renderer's atlas was rasterised for.
    private(set) var scale: CGFloat

    /// - Parameter scale: the display's backing scale factor. Glyphs are
    ///   rasterised at `font size * scale` so they are sharp at device
    ///   resolution, and `metrics` is in pixels to match the shader, whose
    ///   coordinate space is the drawable — pixels, not points. Rasterising
    ///   at 1x and laying out in point units on a 2x display is what made the
    ///   text render at half size and look soft.
    /// - Parameter atlasPixelSize: atlas texture edge length; tests pass a
    ///   small value to exercise atlas eviction.
    init(device: MTLDevice, font: CTFont, scale: CGFloat, atlasPixelSize: Int = GlyphAtlas.atlasSize) throws {
        let atlasFont = CTFontCreateCopyWithAttributes(
            font, CTFontGetSize(font) * scale, nil, nil)
        self.quadRenderer = try QuadRenderer(device: device)
        self.glyphAtlas = GlyphAtlas(device: device, font: atlasFont, atlasPixelSize: atlasPixelSize)
        self.pointMetrics = CellMetrics(font: font, scale: scale)
        self.metrics = self.pointMetrics.scaled(by: scale)
        self.scale = scale
    }

    /// Adopts a new font size, reusing the pipelines and the atlas texture.
    ///
    /// The alternative — building a new `TerminalRenderer` — recompiled the
    /// render pipeline states and allocated a new atlas texture on every
    /// keystroke, which is what made cmd-=/cmd-- stutter under key repeat.
    func setFont(_ font: CTFont, scale newScale: CGFloat) {
        let atlasFont = CTFontCreateCopyWithAttributes(
            font, CTFontGetSize(font) * newScale, nil, nil)
        glyphAtlas.reset(font: atlasFont)
        pointMetrics = CellMetrics(font: font, scale: newScale)
        metrics = pointMetrics.scaled(by: newScale)
        scale = newScale
        invalidate()
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
        grid: Grid, scrollOffset: Int, cursorVisible: Bool, selection: TerminalSelection?,
        searchMatches: [TerminalSelection] = [], currentSearchMatchIndex: Int? = nil,
        hoveredLink: TerminalSelection? = nil
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
        // An atlas eviction mid-build invalidates every UV handed out so far
        // (see `GlyphAtlas`'s type comment), so a generation change forces a
        // second full build. Only one retry: content that alone exceeds the
        // atlas evicts again on every attempt, and those cells draw blank.
        let atlasGeneration = glyphAtlas.generation
        if fullRebuild {
            rebuildAllRows(grid: grid, offset: offset)
        } else {
            changed = rebuildDamagedRows(grid: grid, offset: offset)
        }
        if glyphAtlas.generation != atlasGeneration {
            rebuildAllRows(grid: grid, offset: offset)
            changed = true
        }

        if fullRebuild || !Self.selectionsEqual(cachedSelection, selection)
            || grid.cursor != cachedCursor || grid.cursorStyle != cachedCursorStyle
            || cursorVisible != cachedCursorVisible
            // Output that scrolled lines into history shifts the selection's
            // viewport rows without the selection itself changing.
            || (selection != nil && cachedScrollbackCount != grid.scrollback.count)
            || cachedSearchMatches != searchMatches
            || cachedCurrentSearchMatchIndex != currentSearchMatchIndex
            || !Self.selectionsEqual(cachedHoveredLink, hoveredLink)
        {
            rebuildOverlay(
                grid: grid, cursorVisible: cursorVisible, selection: selection, offset: offset,
                searchMatches: searchMatches, currentSearchMatchIndex: currentSearchMatchIndex,
                hoveredLink: hoveredLink)
            changed = true
        }

        cachedColumns = grid.columns
        cachedOffset = offset
        cachedScrollbackCount = grid.scrollback.count
        cachedCursor = grid.cursor
        cachedCursorStyle = grid.cursorStyle
        cachedCursorVisible = cursorVisible
        cachedSelection = selection
        cachedSearchMatches = searchMatches
        cachedCurrentSearchMatchIndex = currentSearchMatchIndex
        cachedHoveredLink = hoveredLink
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
        searchMatches: [TerminalSelection] = [],
        currentSearchMatchIndex: Int? = nil,
        hoveredLink: TerminalSelection? = nil,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        updateInstances(
            grid: grid, scrollOffset: scrollOffset, cursorVisible: cursorVisible,
            selection: selection, searchMatches: searchMatches,
            currentSearchMatchIndex: currentSearchMatchIndex, hoveredLink: hoveredLink)

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
        // Skipped outright when no cell produced a color glyph — an
        // emoji-free frame pays nothing for the third pipeline.
        if !cachedColorGlyphs.isEmpty {
            quadRenderer.drawColorQuads(
                cachedColorGlyphs, atlas: glyphAtlas.colorTexture, rect: rect,
                drawableSize: drawableSize, renderPassDescriptor: renderPassDescriptor,
                commandBuffer: commandBuffer)
        }
    }

    /// Full rebuild: every row's instances, straight into the cached arrays.
    private func rebuildAllRows(grid: Grid, offset: Int) {
        cachedBackground.removeAll(keepingCapacity: true)
        cachedGlyphs.removeAll(keepingCapacity: true)
        cachedColorGlyphs.removeAll(keepingCapacity: true)
        backgroundCounts.removeAll(keepingCapacity: true)
        glyphCounts.removeAll(keepingCapacity: true)
        colorGlyphCounts.removeAll(keepingCapacity: true)
        cachedLines.removeAll(keepingCapacity: true)
        cachedBackground.reserveCapacity(grid.rows * grid.columns / 4 + 2)
        cachedGlyphs.reserveCapacity(grid.rows * grid.columns / 2)
        for row in 0..<grid.rows {
            let line = Self.visibleLine(grid: grid, row: row, offset: offset)
            let backgroundStart = cachedBackground.count
            let glyphStart = cachedGlyphs.count
            let colorGlyphStart = cachedColorGlyphs.count
            appendRowInstances(
                line: line, row: row, graphemes: grid.graphemes,
                background: &cachedBackground, glyphs: &cachedGlyphs,
                colorGlyphs: &cachedColorGlyphs)
            backgroundCounts.append(cachedBackground.count - backgroundStart)
            glyphCounts.append(cachedGlyphs.count - glyphStart)
            colorGlyphCounts.append(cachedColorGlyphs.count - colorGlyphStart)
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
        var colorGlyphStart = 0
        for row in 0..<grid.rows {
            let line = Self.visibleLine(grid: grid, row: row, offset: offset)
            if line != cachedLines[row] {
                rowBackground.removeAll(keepingCapacity: true)
                rowGlyphs.removeAll(keepingCapacity: true)
                rowColorGlyphs.removeAll(keepingCapacity: true)
                appendRowInstances(
                    line: line, row: row, graphemes: grid.graphemes,
                    background: &rowBackground, glyphs: &rowGlyphs,
                    colorGlyphs: &rowColorGlyphs)
                cachedBackground.replaceSubrange(
                    backgroundStart..<(backgroundStart + backgroundCounts[row]), with: rowBackground)
                cachedGlyphs.replaceSubrange(
                    glyphStart..<(glyphStart + glyphCounts[row]), with: rowGlyphs)
                cachedColorGlyphs.replaceSubrange(
                    colorGlyphStart..<(colorGlyphStart + colorGlyphCounts[row]), with: rowColorGlyphs)
                backgroundCounts[row] = rowBackground.count
                glyphCounts[row] = rowGlyphs.count
                colorGlyphCounts[row] = rowColorGlyphs.count
                cachedLines[row] = line
                changed = true
                rebuilt += 1
            }
            backgroundStart += backgroundCounts[row]
            glyphStart += glyphCounts[row]
            colorGlyphStart += colorGlyphCounts[row]
        }
        lastRebuiltRowCount = rebuilt
        return changed
    }

    /// Selection, search-match and cursor quads, rebuilt when any changes
    /// and spliced into the tail of `cachedBackground`, after every row's
    /// slice.
    private func rebuildOverlay(
        grid: Grid, cursorVisible: Bool, selection: TerminalSelection?, offset: Int,
        searchMatches: [TerminalSelection] = [], currentSearchMatchIndex: Int? = nil,
        hoveredLink: TerminalSelection? = nil
    ) {
        let cellWidth = Float(metrics.cellWidth)
        let cellHeight = Float(metrics.cellHeight)
        overlayScratch.removeAll(keepingCapacity: true)
        if let selection {
            overlayScratch.append(
                contentsOf: selectionQuads(
                    selection, grid: grid, offset: offset, cellWidth: cellWidth, cellHeight: cellHeight,
                    color: Self.selectionColor))
        }
        // All matches highlight; the current one highlights differently
        // (M4.4). Drawn after the selection and before the cursor, so the
        // cursor still reads as the topmost quad if they overlap.
        for (index, match) in searchMatches.enumerated() {
            overlayScratch.append(
                contentsOf: selectionQuads(
                    match, grid: grid, offset: offset, cellWidth: cellWidth, cellHeight: cellHeight,
                    color: index == currentSearchMatchIndex ? Self.currentSearchMatchColor : Self.searchMatchColor))
        }
        // The hovered link's underline (M7.9). A rule rather than a fill:
        // a link under the pointer has to read as a link, and filling it
        // would compete with the selection highlight it can overlap.
        if let hoveredLink {
            for quad in selectionQuads(
                hoveredLink, grid: grid, offset: offset, cellWidth: cellWidth,
                cellHeight: cellHeight, color: Self.linkUnderlineColor)
            {
                let thickness = max(1, Float(scale).rounded(.down))
                overlayScratch.append(
                    QuadInstance(
                        origin: .init(quad.origin.x, quad.origin.y + cellHeight - thickness * 2),
                        size: .init(quad.size.x, thickness), color: quad.color))
            }
        }
        if cursorVisible {
            let cellOrigin = SIMD2<Float>(
                Float(grid.cursor.column) * cellWidth, Float(grid.cursor.row) * cellHeight)
            // DECSCUSR (M2.5/D.4): the core tracks the style, the renderer
            // draws it. Blinking variants render steady — the damage model
            // redraws on change, and a blink timer would force a frame every
            // interval on an otherwise idle screen (`PERFORMANCE.md` §1:
            // idle CPU ~0%).
            //
            // The stroke is an eighth of a cell (2pt at the 2x baseline),
            // floored at 2 device pixels so it stays visible at 1x.
            let stroke = max(2, (cellHeight / 8).rounded(.down))
            switch grid.cursorStyle {
            case .block, .blinkingBlock:
                overlayScratch.append(
                    QuadInstance(origin: cellOrigin, size: .init(cellWidth, cellHeight), color: Self.cursorColor))
            case .underline, .blinkingUnderline:
                overlayScratch.append(
                    QuadInstance(
                        origin: .init(cellOrigin.x, cellOrigin.y + cellHeight - stroke),
                        size: .init(cellWidth, stroke), color: Self.cursorColor))
            case .bar, .blinkingBar:
                overlayScratch.append(
                    QuadInstance(
                        origin: cellOrigin, size: .init(stroke, cellHeight), color: Self.cursorColor))
            }
        }
        let end = cachedBackground.count
        cachedBackground.replaceSubrange((end - overlayCount)..<end, with: overlayScratch)
        overlayCount = overlayScratch.count
    }

    /// Every instance one viewport row contributes — the per-cell loop that
    /// used to run for the whole screen every frame, now run only for rows
    /// whose line actually changed.
    ///
    /// A wide pair's lead cell draws its glyph across the full two-cell box
    /// (M3.5), *scaled down to fit* when the fallback font's bitmap is larger
    /// — the CJK font Core Text falls back to has its own metrics and is
    /// never exactly two primary-font advances wide, and trusting it is what
    /// made CJK spill into the next cell or draw at the wrong width. A cell
    /// whose grapheme cluster spills to the side table (`DESIGN.md` §2.3,
    /// M3.6) is shaped as one run and drawn into the same box — one cell, or
    /// two for a wide cluster such as a ZWJ emoji.
    private func appendRowInstances(
        line: Line, row: Int, graphemes: GraphemeTable,
        background: inout [QuadInstance], glyphs: inout [QuadInstance],
        colorGlyphs: inout [QuadInstance]
    ) {
        let cellWidth = Float(metrics.cellWidth)
        let cellHeight = Float(metrics.cellHeight)
        let baseline = Float(metrics.baselineOffset)
        // Read once per row, not per cell: the static accessor goes through
        // a global and retains the theme's ANSI array every time it is
        // touched, and this loop runs tens of thousands of times a frame.
        let palette = TerminalColorPalette.activeVariant
        // Shell-integration mark (M7.2): a two-pixel rule down the left edge
        // of a prompt row, coloured by how that command ended. It is the only
        // way to see at a glance which of the last twenty commands failed,
        // and it costs one comparison per row rather than per cell. Drawn
        // inside the first cell rather than in the window inset, because the
        // inset is outside the rect this renderer is given and quads there
        // would fall outside the pane.
        if line.mark != .none {
            let width = max(2, Float(scale) * 2)
            background.append(
                QuadInstance(
                    origin: .init(0, Float(row) * cellHeight),
                    size: .init(width, cellHeight),
                    color: Self.markColor(line.mark)))
        }
        for column in 0..<line.count {
            let cell = line[column]
            // Read once as a raw bitfield and test with masks. Every
            // `OptionSet.contains` in this loop is an unelided call in a
            // debug build, and the loop runs once per cell per frame
            // (`PERFORMANCE.md` §3).
            let attributes = cell.attributes.rawValue
            let reversed = attributes & CellAttributes.reverse.rawValue != 0
            // Resolve each colour in its own role first, `.default` and all,
            // then swap the two resolved values for reverse video. Passing
            // the swapped *raw* colours into `resolveForeground`/
            // `resolveBackground` instead (as this used to) is wrong for the
            // common case: `.default` foreground and `.default` background
            // both re-resolve to the same defaults regardless of which
            // resolver they go through, so a plain reversed cell — a
            // `less` search hit is one — came out identical to an
            // unreversed one, with no visible highlight at all.
            let resolvedFg = palette.resolveForeground(cell.foreground)
            let resolvedBg = palette.resolveBackground(cell.background)
            var fg = reversed ? resolvedBg : resolvedFg
            let bg = reversed ? resolvedFg : resolvedBg
            // SGR 2 (dim). Parsed since M1 and drawn nowhere until now, so
            // `git log --oneline`'s hashes, `ls -l`'s metadata and every
            // spinner's hint line came out at full strength and the
            // distinction the program was drawing was simply lost.
            //
            // Applied as alpha on the foreground rather than as a blend
            // towards the background: the glyph quads already carry a
            // per-instance alpha (the block-element path above uses it), so
            // this costs one multiply and no extra branch downstream, and it
            // stays correct over a cell that has its own background colour —
            // interpolating towards the *default* background would tint dim
            // text on a coloured run.
            if attributes & CellAttributes.dim.rawValue != 0 { fg.w *= Self.dimAlpha }

            let origin = SIMD2<Float>(Float(column) * cellWidth, Float(row) * cellHeight)
            if !(reversed ? cell.foreground : cell.background).isDefault || reversed {
                background.append(
                    QuadInstance(origin: origin, size: .init(cellWidth, cellHeight), color: bg))
            }

            // Underline and strikethrough are rules, not glyphs: one quad
            // each, in the cell's foreground. An OSC 8 hyperlink (M6.8)
            // draws the same underline whether or not the program also set
            // SGR 4 — that rule is what makes it read as a link, and
            // `ls --hyperlink` sets no rendition at all.
            // One mask test for the whole rule/visibility group, off the
            // `attributes` already loaded at the top of the iteration.
            let hasRuleOrHiddenWork =
                attributes & Self.ruleAttributeMask != 0 || !cell.hyperlink.isNone
            let isInvisible = attributes & CellAttributes.invisible.rawValue != 0
            if hasRuleOrHiddenWork, !isInvisible,
                attributes & CellAttributes.underline.rawValue != 0 || !cell.hyperlink.isNone
            {
                // One device pixel, sitting just below the baseline. A
                // wide pair's spacer draws it too, so the rule runs the
                // full width of a double-width character rather than
                // stopping halfway.
                let thickness = max(1, Float(scale).rounded(.down))
                background.append(
                    QuadInstance(
                        origin: .init(origin.x, origin.y + baseline + thickness),
                        size: .init(cellWidth, thickness), color: fg))
            }
            if hasRuleOrHiddenWork, !isInvisible,
                attributes & CellAttributes.strikethrough.rawValue != 0
            {
                let thickness = max(1, Float(scale).rounded(.down))
                background.append(
                    QuadInstance(
                        // Roughly mid x-height. The exact strike position
                        // is a font metric Core Text will give, but it is
                        // per-font and this is a rule across a fixed cell.
                        origin: .init(origin.x, origin.y + baseline * 0.7),
                        size: .init(cellWidth, thickness), color: fg))
            }

            // A wide pair's spacer holds a space scalar and draws nothing;
            // the flag check keeps that true even if the scalar ever
            // changes.
            guard !isInvisible, attributes & CellAttributes.wideSpacer.rawValue == 0
            else { continue }
            // Block elements are geometry, not glyphs: rounding the cell up
            // from a fractional advance leaves every glyph a point short of
            // its cell, which between block characters is a visible grid of
            // gaps and a cell average well below the requested colour
            // (`BlockElements`). Drawn as rects they meet exactly.
            if let pieces = BlockElements.pieces(for: cell.scalar) {
                for piece in pieces {
                    background.append(
                        QuadInstance(
                            origin: .init(
                                origin.x + piece.rect.x * cellWidth,
                                origin.y + piece.rect.y * cellHeight),
                            size: .init(piece.rect.z * cellWidth, piece.rect.w * cellHeight),
                            color: .init(fg.x, fg.y, fg.z, fg.w * piece.alpha)))
                }
                continue
            }

            // Bold and italic together, straight off the already-loaded
            // rawValue: two bit tests and no `OptionSet.contains` call, which
            // this loop cannot afford (`PERFORMANCE.md` §3).
            let style = GlyphAtlas.Style(
                rawValue: UInt8(
                    (attributes & CellAttributes.bold.rawValue != 0 ? 1 : 0)
                        | (attributes & CellAttributes.italic.rawValue != 0 ? 2 : 0)))
            let isWide = attributes & CellAttributes.wide.rawValue != 0
            let info: GlyphAtlas.GlyphInfo
            if !cell.grapheme.isNone,
                let scalars = graphemes.scalars(for: cell.grapheme)
            {
                // A cluster cell is drawn even when its base scalar is a
                // space (a combining mark can attach to one).
                guard let shaped = glyphAtlas.glyph(forCluster: scalars, style: style)
                else { continue }
                info = shaped
            } else {
                guard cell.scalar != 0x20, let scalar = Unicode.Scalar(cell.scalar)
                else { continue }
                guard
                    let lookedUp =
                        scalar.isASCII
                        ? glyphAtlas.glyph(forASCII: cell.scalar, style: style)
                        : glyphAtlas.glyph(shaping: cell.scalar, style: style)
                else { continue }
                info = lookedUp
            }
            // No font in the cascade covers this scalar. Drawing nothing
            // would make the terminal look like it dropped the output, so
            // the cell gets the conventional hollow box instead — the same
            // information a `.notdef` glyph carries, without trusting a font
            // to supply one.
            if info.isMissing {
                appendMissingGlyphBox(
                    at: origin, cellWidth: cellWidth * (isWide ? 2 : 1), cellHeight: cellHeight,
                    color: fg, into: &background)
                continue
            }
            guard info.size != .zero else { continue }

            var glyphOrigin = SIMD2<Float>(
                origin.x + info.bearing.x,
                origin.y + baseline - info.bearing.y - info.size.y
            )
            var glyphSize = info.size
            let boxWidth = isWide ? cellWidth * 2 : cellWidth
            // Does the glyph's own ink — the bitmap less the atlas's one-texel
            // border on each side — fit the box it is allowed to paint?
            //
            // For a wide pair this has always been the rule: the CJK font
            // Core Text falls back to has its own metrics and is never
            // exactly two primary advances wide. It is now the rule for every
            // cell, because a font whose bold face advances a shade wider
            // than its regular one — or one that is monospaced for letters
            // and not for symbols — spills its ink into the neighbouring
            // column, and nothing downstream clips a glyph quad to its cell.
            // The tolerance is one device pixel: rounding and the padding
            // must not drag ordinary text off the fast path below.
            let ink = info.size.x - 2 * GlyphAtlas.bitmapPadding
            if isWide || ink > boxWidth + 1 {
                // Scale down into the box (never up), then centre
                // horizontally; the baseline fixes the vertical axis, so
                // scaled bearings keep the glyph sitting on the line. The
                // quad can then never paint outside its own cells.
                let fit = min(1, boxWidth / info.size.x, cellHeight / info.size.y)
                glyphSize = info.size * fit
                glyphOrigin = SIMD2<Float>(
                    origin.x + (boxWidth - glyphSize.x) / 2,
                    origin.y + baseline - (info.bearing.y + info.size.y) * fit
                )
            } else if !info.isColor {
                // The atlas already contains Core Text's antialiasing.
                // Sampling that bitmap from a fractional destination origin
                // filters it a second time and makes 12pt ASCII look soft.
                // Ordinary coverage glyphs are 1:1 with the drawable, so
                // align their quads to the device-pixel grid. Scaled and
                // color glyphs keep linear sampling.
                glyphOrigin.x = glyphOrigin.x.rounded()
                glyphOrigin.y = glyphOrigin.y.rounded()
            }
            // Color glyphs (Apple Color Emoji bitmaps in the RGBA atlas)
            // draw in the color pass, which ignores the tint — routing one
            // through the coverage pipeline would render a monochrome
            // silhouette. The wide-glyph scale-and-centre above applies to
            // both paths, so an emoji sits centred on its two-cell box.
            let instance = QuadInstance(origin: glyphOrigin, size: glyphSize, color: fg, uvRect: info.uvRect)
            if info.isColor {
                colorGlyphs.append(instance)
            } else {
                glyphs.append(instance)
            }
        }
    }

    /// The hollow box drawn in place of a scalar no font can render. Four
    /// rules, one device pixel thick, inset far enough from the cell edges
    /// that a run of them reads as separate boxes rather than a grid.
    private func appendMissingGlyphBox(
        at origin: SIMD2<Float>, cellWidth: Float, cellHeight: Float, color: SIMD4<Float>,
        into background: inout [QuadInstance]
    ) {
        let thickness = max(1, Float(scale).rounded(.down))
        let inset = max(thickness, (cellWidth * 0.12).rounded())
        let top = origin.y + max(thickness, (cellHeight * 0.15).rounded())
        let width = max(thickness * 2, cellWidth - inset * 2)
        let height = max(thickness * 2, cellHeight - (top - origin.y) * 2)
        let left = origin.x + inset
        background.append(
            QuadInstance(origin: .init(left, top), size: .init(width, thickness), color: color))
        background.append(
            QuadInstance(
                origin: .init(left, top + height - thickness), size: .init(width, thickness),
                color: color))
        background.append(
            QuadInstance(origin: .init(left, top), size: .init(thickness, height), color: color))
        background.append(
            QuadInstance(
                origin: .init(left + width - thickness, top), size: .init(thickness, height),
                color: color))
    }

    /// Green for a command that succeeded, red for one that failed, and a
    /// neutral grey for a prompt whose command has not reported yet — which
    /// includes the one currently running.
    private static func markColor(_ mark: LineMark) -> SIMD4<Float> {
        switch mark {
        case .promptSucceeded: return SIMD4<Float>(0.25, 0.75, 0.35, 0.85)
        case .promptFailed: return SIMD4<Float>(0.9, 0.3, 0.25, 0.9)
        default: return SIMD4<Float>(0.55, 0.55, 0.6, 0.55)
        }
    }

    private static func selectionsEqual(_ a: TerminalSelection?, _ b: TerminalSelection?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?):
            return a.start == b.start && a.end == b.end
                && a.baseScrollbackTotal == b.baseScrollbackTotal
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
    /// against a scrollback of `baseScrollbackTotal` lines; two shifts map
    /// them onto what is on screen now: `growth` for output that pushed
    /// lines into history since, and `offset` for the user's own scrolling.
    /// Rows outside the viewport produce no quads.
    private func selectionQuads(
        _ selection: TerminalSelection, grid: Grid, offset: Int, cellWidth: Float, cellHeight: Float,
        color: SIMD4<Float>
    ) -> [QuadInstance] {
        guard selection.start.row <= selection.end.row else { return [] }
        let growth = max(0, grid.scrollback.count - selection.baseScrollbackTotal)
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
                    color: color))
        }
        return quads
    }
}
