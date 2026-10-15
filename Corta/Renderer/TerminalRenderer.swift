// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import CoreText
import CortaTerminal
import Foundation
import Metal
import Synchronization

/// A document position; negative rows are scrollback. Never a viewport row:
/// scrolling translates, it does not move the selection.
nonisolated struct GridPosition: Equatable {
    var row: Int
    var column: Int
}

public nonisolated struct TerminalSelection: Equatable, Sendable {
    var start: GridPosition
    var end: GridPosition
    /// `totalPushed` when recorded; the renderer shifts rows by the growth.
    /// Not `.count`, which saturates and let the highlight drift.
    var baseScrollbackTotal: Int = 0
}

/// A `Grid` snapshot as instanced quads, drawn into a rect: background,
/// glyphs, and color emoji when present.
///
/// **Damage tracking** (`PERFORMANCE.md` §3): the live screen compares a
/// `UInt64` revision per row; scrolled into history, where rows carry none,
/// `Line` values. Only damaged rows are rebuilt; a static frame reports no
/// damage, so the shell skips it entirely (idle ~0% CPU).
///
/// Cursor and selection are background-pass quads — colour under the glyph —
/// not another pipeline. A block cursor is part of its row, not the overlay:
/// an opaque cell in the cursor colour whose character is drawn in the
/// theme background, so moving it rebuilds the row it left and the row it
/// entered, one each.
///
/// `public`, with the few members `CortaPerformanceTests` drives: that bundle
/// imports the app without `@testable`, because `-enable-testing` inhibits
/// the optimisation its Release figure exists to measure (#110).
public nonisolated final class TerminalRenderer: @unchecked Sendable {
    private let access = NSRecursiveLock()
    func withExclusiveAccess<T>(_ body: () throws -> T) rethrows -> T {
        access.lock()
        defer { access.unlock() }
        return try body()
    }
    private(set) var backend: Metal4Backend
    private(set) var backendGeneration = 0
    private var recoveryAttempts = 0
    /// Keep resources of old in-flight frames alive while the new queue draws.
    /// At most three replaced queues are retained per renderer.
    private var retiredBackends: [Metal4Backend] = []
    /// The idle cursor's one-cell captures, kept: a queue and its frame
    /// slots per capture was a fresh allocation every time a cursor parked.
    var captureBackend: Metal4Backend?
    let glyphAtlas: GlyphAtlas
    private struct Geometry: Sendable {
        var metrics: CellMetrics
        var points: CellMetrics
        var scale: CGFloat
    }
    private let geometry: Mutex<Geometry>
    var metricsValue: CellMetrics
    /// Its own texture cache: images share no eviction policy with glyphs.
    let kittyImageRenderer: KittyImageRenderer
    /// Cached because `draw` takes no `Grid`.
    private var cachedImagePlacements = ImagePlacementTable()

    // MARK: - Damage-tracked instance cache

    /// Earliest time this cached grid could contain an echo. Set before snapshotting,
    /// never at submission: output may arrive while older instances are encoded.
    var echoSnapshotAt: TimeInterval?
    var cachedLines: [Line] = []
    /// Live-screen fast path only; meaningless for rows rebuilt in history.
    var cachedRevisions: [UInt64] = []
    var backgroundCounts: [Int] = []
    var glyphCounts: [Int] = []
    var colorGlyphCounts: [Int] = []
    var cachedBackground: ContiguousArray<QuadInstance> = []
    var cachedGlyphs: ContiguousArray<QuadInstance> = []
    /// Their own pass: the coverage pipeline reduces emoji to a silhouette.
    var cachedColorGlyphs: ContiguousArray<QuadInstance> = []
    var overlayCount = 0
    private var cachedColumns = 0
    var cachedOffset = -1
    /// Not `.count`: a full ring would look unscrolled and leave stale quads.
    private var cachedScrollbackTotalPushed = -1
    /// A swapped-in `ScreenLines` restarts revisions; see its `generation`.
    private var cachedLinesGeneration: UInt64?
    /// An OSC 4 change alters what an index resolves to, invisible to every
    /// other check.
    private var cachedIndexedOverridesGeneration: UInt64 = 0
    var indexedOverrides: IndexedColorOverrides = [:]
    /// Journal sequence within cachedLinesGeneration, replayed in order.
    var cachedScrollEventsTotal: UInt64 = 0
    var cachedDocumentTop = 0
    /// Newly exposed history rows must rebuild even when their value is blank.
    var invalidRows: [Bool] = []
    private var cachedCursor: Cursor?
    private var cachedCursorStyle: CursorStyle?
    private var cachedCursorVisible = false
    private var cachedSelection: TerminalSelection?
    private var cachedSearchMatches: [TerminalSelection] = []
    private var cachedCurrentSearchMatchIndex: Int?
    private var cachedHoveredLink: TerminalSelection?
    private var needsFullRebuild = true

    /// Non-ASCII shapes one frame may run (`GlyphAtlas.beginFrame`): about
    /// 20 ms of Core Text at the slowest measured rate, so a hostile screen of
    /// distinct clusters cannot hold the main thread for a whole screen's
    /// worth each frame. A first paint of more fills in over a few frames.
    static let shapingBudgetPerFrame = 1024

    /// Called when a frame left glyphs unshaped for want of budget and the
    /// atlas still has room for them: draw again soon, or they wait for the
    /// next output. Not called when the frame evicted, since content that
    /// overflows the atlas would then ask for frames forever.
    var onGlyphsDeferred: (() -> Void)?

    /// Where the rows draw a block cursor: a screen row and column, live
    /// screen only. It lives in the row instances, so a row is stale when
    /// the cursor enters or leaves it, or when a scroll shift carries a
    /// baked cursor to another row.
    struct BlockCursor: Equatable {
        var row: Int
        var column: Int
    }
    var blockCursor: BlockCursor?
    /// Rows the damage pass rebuilds whatever their revision says: the
    /// block cursor's old and new rows. -1 is none; two `Int`s, not a set,
    /// so the per-row test allocates nothing.
    var forcedRowA = -1
    var forcedRowB = -1

    /// Reused, so a damaged row allocates nothing: every damaged row's new
    /// instances, back to back, with where each row's are.
    var rowBackground: ContiguousArray<QuadInstance> = []
    var rowGlyphs: ContiguousArray<QuadInstance> = []
    var rowColorGlyphs: ContiguousArray<QuadInstance> = []
    var rebuiltRows: [RebuiltRow] = []
    /// The next cache while a splice builds it, then the old one's storage.
    var spliceBuffer: ContiguousArray<QuadInstance> = []

    /// One damaged row: its instances in the row scratch arrays, and where
    /// its old ones start in the cache.
    struct RebuiltRow {
        var row: Int
        var background: Range<Int>
        var glyphs: Range<Int>
        var colorGlyphs: Range<Int>
        var cachedBackgroundStart: Int
        var cachedGlyphStart: Int
        var cachedColorGlyphStart: Int
    }
    var overlayScratch: ContiguousArray<QuadInstance> = []

    /// One test rejects nearly every cell.
    static let ruleAttributes: CellAttributes = [.underline, .strikethrough, .invisible]

    /// Secondary but readable on dark and light; zero is `invisible`'s job.
    static let dimAlpha: Float = 0.55
    static let colorAttributeMask = CellAttributes.reverse.rawValue | CellAttributes.dim.rawValue

    var lastRebuiltRowCount = 0

    /// This renderer's theme, instead of the live one (`TerminalColorPalette`).
    /// For tests: the live palette is process-wide, and a suite that pinned it
    /// was rendering whatever another suite had just applied.
    var themeVariant: Theme.Variant?

    /// The theme this frame's rows are built with, read once per
    /// `updateInstances` — one lock on the shared palette per frame rather
    /// than per row, and no frame half in one theme and half in the next.
    var framePalette: Theme.Variant = Theme.corta.dark
    /// `framePalette`'s derived colours, worked out once per frame.
    var frameOverlay = Theme.corta.dark.overlayColors
    /// The command-status rules beside prompts (`command-status-marks`).
    /// Drawn in this pass, in the left margin, so a rule shows the frame's
    /// own rows: drawn by AppKit they led the text by a frame or two and took
    /// the colour of the command below (#238).
    var drawsCommandMarks = true {
        didSet { if drawsCommandMarks != oldValue { marksAreStale = true } }
    }
    /// The rules, in the margin rect's space (`markRect`); rebuilt when the
    /// rows are, or when `drawsCommandMarks` changes.
    var cachedMarks: ContiguousArray<QuadInstance> = []
    private var marksAreStale = true

    /// Resource counters used by Release measurement drivers.
    public var atlasAllocatedBytes: Int { glyphAtlas.texture.allocatedSize + glyphAtlas.colorTexture.allocatedSize }
    public var instanceStride: Int { MemoryLayout<QuadInstance>.stride }
    public var uploadedInstanceBytes: Int { backend.uploadedInstanceBytes }
    public var uploadedRectangleBytes: Int { backend.uploadedRectangleBytes }

    /// Rows in the cached frame: the grid height `draw` lays out.
    var cachedRowCount: Int { cachedLines.count }

    /// Per-row counts as well as instance order belong to the cache contract.
    var cachedInstanceCounts: [[Int]] { [backgroundCounts, glyphCounts, colorGlyphCounts] }

    /// The cached instances — background, glyphs, colour glyphs — so an
    /// incremental build can be compared with a full one.
    var cachedInstances: [ContiguousArray<QuadInstance>] {
        [cachedBackground, cachedGlyphs, cachedColorGlyphs]
    }

    var scaleValue: CGFloat

    public var metrics: CellMetrics { geometry.withLock { $0.metrics } }
    var pointMetrics: CellMetrics { geometry.withLock { $0.points } }
    var scale: CGFloat { geometry.withLock { $0.scale } }

    /// - Parameter device: a GPU in `MTLGPUFamily.metal4`.
    /// - Parameter font: the primary font, at its point size.
    /// - Parameter scaleValue: glyphs rasterise at `size × scale` and `metrics` are
    ///   pixels, the shader's space; 1× on a 2× display rendered half-size and
    ///   soft.
    /// - Parameter atlasPixelSize: small in tests, to exercise eviction;
    ///   `nil` is `GlyphAtlas.atlasSize`.
    /// - Parameter atlasStorageMode: the atlas texture's storage.
    /// - Throws: `Metal4BackendError.metal4Unsupported` on a GPU without
    ///   `MTLGPUFamily.metal4`. There is no other renderer to fall back to.
    public init(
        device: MTLDevice, font: CTFont, scale scaleValue: CGFloat, atlasPixelSize: Int? = nil, atlasStorageMode: MTLStorageMode = .shared) throws {
        let atlasFont = CTFontCreateCopyWithAttributes(
            font, CTFontGetSize(font) * scaleValue, nil, nil)
        self.backend = try Metal4Backend(device: device)
        // The atlas is per pane, unlike the pipelines: it is mutable and its
        // eviction forces full rebuilds, so sharing would couple every pane's
        // damage tracking to other panes' glyph churn. Lazy allocation makes
        // a prompt's atlas small; the ceiling is still about 20 MiB per pane.
        // A shared read-only ASCII layer would be a new design, not a lookup.
        self.glyphAtlas = try GlyphAtlas(
            device: device, font: atlasFont, atlasPixelSize: atlasPixelSize ?? GlyphAtlas.atlasSize, storageMode: atlasStorageMode)
        self.kittyImageRenderer = KittyImageRenderer(device: device)
        let points = CellMetrics(font: font, scale: scaleValue)
        self.metricsValue = points.scaled(by: scaleValue)
        self.scaleValue = scaleValue
        self.geometry = Mutex(
            Geometry(metrics: metricsValue, points: points, scale: scaleValue))
        // A reset or eviction while a frame is queued moves the atlas to
        // fresh textures; the old ones go when those frames complete.
        glyphAtlas.texturesInUse = { [weak self] in
            guard let self else { return false }
            return self.backend.hasFramesInFlight
                || self.retiredBackends.contains { $0.hasFramesInFlight }
        }
        glyphAtlas.onTextureRetired = { [weak self] texture in
            self?.backend.retireTexture(texture)
        }
    }

    /// Reuses pipelines and texture; a new renderer per keystroke stuttered
    /// under key repeat.
    func setFont(_ font: CTFont, scale newScale: CGFloat) {
        access.lock()
        defer { access.unlock() }
        let atlasFont = CTFontCreateCopyWithAttributes(
            font, CTFontGetSize(font) * newScale, nil, nil)
        glyphAtlas.reset(font: atlasFont)
        let points = CellMetrics(font: font, scale: newScale)
        metricsValue = points.scaled(by: newScale)
        scaleValue = newScale
        geometry.withLock {
            $0 = Geometry(metrics: metricsValue, points: points, scale: scaleValue)
        }
        invalidate()
    }

    /// For the frame-CPU baseline's worst case.
    public func invalidate() {
        access.lock()
        defer { access.unlock() }
        needsFullRebuild = true
    }

    /// Reconstructs a faulted/stalled queue, preserving the session and caches.
    /// Present each frame by copy through a classic queue, so a full-screen
    /// pane can reach the display directly (`Metal4Backend.presentsByCopy`).
    public var presentsByCopy: Bool {
        get { access.withLock { backend.presentsByCopy } }
        set { access.withLock { backend.presentsByCopy = newValue } }
    }

    /// An unusable device cannot cause an unlimited reconstruction loop.
    @discardableResult
    func recoverBackendIfNeeded() throws -> Bool {
        access.lock()
        defer { access.unlock() }
        retiredBackends.removeAll { !$0.hasFramesInFlight }
        guard backend.requiresRecovery else { return false }
        guard recoveryAttempts < 3 else { throw Metal4BackendError.recoveryExhausted }
        recoveryAttempts += 1
        let replacement = try Metal4Backend(device: backend.device)
        replacement.presentsByCopy = backend.presentsByCopy
        retiredBackends.append(backend)
        backend = replacement
        backendGeneration += 1
        return true
    }

    /// `false`: the cache still matches and the frame can be skipped. Size
    /// changes rebuild; scrolling shifts the retained document rows.
    @discardableResult
    func updateInstances(
        grid: Grid, scrollOffset: Int, cursorVisible: Bool, selection: TerminalSelection?,
        searchMatches: [TerminalSelection] = [], currentSearchMatchIndex: Int? = nil,
        hoveredLink: TerminalSelection? = nil,
        indexedOverrides: IndexedColorOverrides = [:], indexedOverridesGeneration: UInt64 = 0,
        cursorStyle: CursorStyle? = nil
    ) -> Bool {
        access.lock()
        defer { access.unlock() }
        let effectiveCursorStyle = cursorStyle ?? grid.cursorStyle
        self.indexedOverrides = indexedOverrides
        framePalette = themeVariant ?? TerminalColorPalette.activeVariant
        frameOverlay = framePalette.overlayColors
        let offset = min(max(0, scrollOffset), grid.scrollback.count)
        let fullRebuild = cacheIsStale(for: grid, indexedOverridesGeneration: indexedOverridesGeneration)

        let previousBlockCursor = blockCursor
        let isBlock = effectiveCursorStyle == .block || effectiveCursorStyle == .blinkingBlock
        blockCursor =
            isBlock && cursorVisible && offset == 0
            ? BlockCursor(row: grid.cursor.row, column: grid.cursor.column) : nil
        let atlasGeneration = glyphAtlas.generation
        let rowsChanged = updateRows(
            grid: grid, offset: offset, fullRebuild: fullRebuild,
            previousBlockCursor: previousBlockCursor, atlasGeneration: atlasGeneration)
        var changed = rowsChanged

        if fullRebuild
            || overlayIsStale(
                grid: grid, offset: offset, cursorStyle: effectiveCursorStyle, cursorVisible: cursorVisible,
                selection: selection, searchMatches: searchMatches,
                currentSearchMatchIndex: currentSearchMatchIndex, hoveredLink: hoveredLink)
        {
            rebuildOverlay(
                grid: grid, cursorStyle: effectiveCursorStyle, cursorVisible: cursorVisible, selection: selection, offset: offset,
                searchMatches: searchMatches, currentSearchMatchIndex: currentSearchMatchIndex,
                hoveredLink: hoveredLink)
            changed = true
        }

        if updateImages(grid: grid, offset: offset) {
            changed = true
        }
        remember(
            grid: grid, offset: offset, indexedOverridesGeneration: indexedOverridesGeneration,
            cursorStyle: effectiveCursorStyle, cursorVisible: cursorVisible, selection: selection,
            searchMatches: searchMatches, currentSearchMatchIndex: currentSearchMatchIndex,
            hoveredLink: hoveredLink)
        requestRebuildForDeferredGlyphs(atlasGeneration: atlasGeneration)
        // Not on a cursor blink or a selection drag: only the rows carry marks.
        if rowsChanged || marksAreStale {
            changed = changed || marksAreStale
            rebuildMarks(alternateScreen: grid.isAlternateScreenActive)
            marksAreStale = false
        }
        return changed
    }

    /// Brings the row instances up to date and reports whether any changed.
    /// An eviction mid-build stales every UV: rebuild once. Content that
    /// alone overflows the atlas draws blank.
    private func updateRows(
        grid: Grid, offset: Int, fullRebuild: Bool, previousBlockCursor: BlockCursor?,
        atlasGeneration: Int
    ) -> Bool {
        glyphAtlas.beginFrame(shapingBudget: Self.shapingBudgetPerFrame)
        var changed = fullRebuild
        if fullRebuild {
            rebuildAllRows(grid: grid, offset: offset)
        } else {
            changed = rebuildDamagedRows(
                grid: grid, offset: offset, previousBlockCursor: previousBlockCursor)
        }
        if glyphAtlas.generation != atlasGeneration {
            rebuildAllRows(grid: grid, offset: offset)
            changed = true
        }
        return changed
    }

    /// Hands the placements to the image renderer and reports whether they
    /// changed. Decodes are scheduled here, never in `draw`; an image delete
    /// changes no cell, so it registers as damage here or not at all.
    private func updateImages(grid: Grid, offset: Int) -> Bool {
        let changed = cachedImagePlacements.revision != grid.imagePlacements.revision
        kittyImageRenderer.update(
            table: grid.imagePlacements, rows: grid.rows, offset: offset,
            scrollbackTotalPushed: grid.scrollback.totalPushed,
            cellHeight: Float(metricsValue.cellHeight))
        return changed
    }

    /// Rows that drew without some glyph are rebuilt next frame. Asked for
    /// only while nothing was evicted: past that the content overflows the
    /// atlas, and re-asking would shape a budget's worth every frame for as
    /// long as it stays on screen.
    private func requestRebuildForDeferredGlyphs(atlasGeneration: Int) {
        needsFullRebuild = glyphAtlas.deferredShaping && glyphAtlas.generation == atlasGeneration
        if needsFullRebuild {
            onGlyphsDeferred?()
        }
    }

    /// Whether every row must be rebuilt: the grid's shape or lines were
    /// replaced, the retained history scrolled out from under the viewport,
    /// or the palette changed.
    private func cacheIsStale(for grid: Grid, indexedOverridesGeneration: UInt64) -> Bool {
        needsFullRebuild
            || cachedLines.count != grid.rows
            || cachedColumns != grid.columns
            || cachedLinesGeneration != grid.linesGeneration
            || (cachedOffset > 0 && cachedDocumentTop < grid.scrollback.totalPushed - grid.scrollback.count)
            || cachedIndexedOverridesGeneration != indexedOverridesGeneration
    }

    /// Whether the cursor, selection, search or link overlay differs from
    /// the one last built.
    private func overlayIsStale(
        grid: Grid, offset: Int, cursorStyle: CursorStyle, cursorVisible: Bool,
        selection: TerminalSelection?, searchMatches: [TerminalSelection],
        currentSearchMatchIndex: Int?, hoveredLink: TerminalSelection?
    ) -> Bool {
        cachedOffset != offset || !Self.selectionsEqual(cachedSelection, selection)
            || grid.cursor != cachedCursor || cursorStyle != cachedCursorStyle
            || cursorVisible != cachedCursorVisible
            // Both are anchored to the scrollback, so output moves them.
            || ((selection != nil || !searchMatches.isEmpty)
                && cachedScrollbackTotalPushed != grid.scrollback.totalPushed)
            || cachedSearchMatches != searchMatches
            || cachedCurrentSearchMatchIndex != currentSearchMatchIndex
            || !Self.selectionsEqual(cachedHoveredLink, hoveredLink)
    }

    /// What the next frame's diff compares against.
    private func remember(
        grid: Grid, offset: Int, indexedOverridesGeneration: UInt64, cursorStyle: CursorStyle,
        cursorVisible: Bool, selection: TerminalSelection?, searchMatches: [TerminalSelection],
        currentSearchMatchIndex: Int?, hoveredLink: TerminalSelection?
    ) {
        cachedColumns = grid.columns
        cachedOffset = offset
        cachedScrollbackTotalPushed = grid.scrollback.totalPushed
        cachedIndexedOverridesGeneration = indexedOverridesGeneration
        cachedLinesGeneration = grid.linesGeneration
        cachedScrollEventsTotal = grid.scrollEventsTotal
        cachedDocumentTop = grid.scrollback.totalPushed - offset
        cachedImagePlacements = grid.imagePlacements
        cachedCursor = grid.cursor
        cachedCursorStyle = cursorStyle
        cachedCursorVisible = cursorVisible
        cachedSelection = selection
        cachedSearchMatches = searchMatches
        cachedCurrentSearchMatchIndex = currentSearchMatchIndex
        cachedHoveredLink = hoveredLink
    }

    /// Diff and draw in one call, for tests and benchmarks; the app's loop
    /// diffs in `PaneFrameLoop.prepareFrame` and calls `draw` directly. `onCompleted`
    /// runs when the GPU has finished the frame.
    public func render(
        grid: Grid,
        scrollOffset: Int = 0,
        rect: CGRect,
        drawableSize: CGSize,
        cursorVisible: Bool,
        selection: TerminalSelection?,
        searchMatches: [TerminalSelection] = [],
        currentSearchMatchIndex: Int? = nil,
        hoveredLink: TerminalSelection? = nil,
        indexedOverrides: IndexedColorOverrides = [:],
        indexedOverridesGeneration: UInt64 = 0,
        target: MTLTexture,
        clearColor: MTLClearColor,
        onCompleted: (@Sendable ((any Error)?) -> Void)? = nil
    ) {
        updateInstances(
            grid: grid, scrollOffset: scrollOffset, cursorVisible: cursorVisible,
            selection: selection, searchMatches: searchMatches,
            currentSearchMatchIndex: currentSearchMatchIndex, hoveredLink: hoveredLink,
            indexedOverrides: indexedOverrides, indexedOverridesGeneration: indexedOverridesGeneration)
        draw(
            rect: rect, drawableSize: drawableSize, target: target, clearColor: clearColor,
            drawable: nil, label: "Corta.render", onCompleted: onCompleted)
    }

    /// Draws the last cached instances, without diffing again, as one render
    /// pass: backgrounds, glyphs, colour glyphs, then images over the text.
    /// The backend owns the command buffer, the commit and the present.
    /// - Returns: whether the frame was drawn; false when the backend dropped
    ///   it, and the drawable was presented with stale contents.
    @discardableResult
    func draw(
        rect: CGRect, drawableSize: CGSize, target: MTLTexture, clearColor: MTLClearColor,
        drawable: (any MTLDrawable)?, label: String,
        onCompleted: (@Sendable ((any Error)?) -> Void)?
    ) -> Bool {
        access.lock()
        defer { access.unlock() }
        let drawing = backend.beginFrame(target: target, clearColor: clearColor, label: label)
        backend.drawSolidQuads(cachedBackground, rect: rect, drawableSize: drawableSize)
        if !cachedMarks.isEmpty {
            backend.drawSolidQuads(cachedMarks, rect: markRect(beside: rect), drawableSize: drawableSize)
        }
        backend.drawGlyphQuads(
            cachedGlyphs, atlas: glyphAtlas.texture, atlasRects: glyphAtlas.atlasRects,
            atlasRectsVersion: glyphAtlas.atlasRectsVersion, rect: rect, drawableSize: drawableSize)
        if !cachedColorGlyphs.isEmpty {
            backend.drawColorQuads(
                cachedColorGlyphs, atlas: glyphAtlas.colorTexture, atlasRects: glyphAtlas.atlasRects,
                atlasRectsVersion: glyphAtlas.atlasRectsVersion, rect: rect,
                drawableSize: drawableSize)
        }
        if cachedImagePlacements.placementCount > 0 {
            kittyImageRenderer.draw(
                table: cachedImagePlacements, cellWidth: Float(metricsValue.cellWidth),
                cellHeight: Float(metricsValue.cellHeight), rows: cachedLines.count, offset: cachedOffset,
                scrollbackTotalPushed: cachedScrollbackTotalPushed, rect: rect,
                drawableSize: drawableSize, backend: backend, drawable: drawable)
        }
        let images = kittyImageRenderer
        backend.endFrame(presenting: drawable, echoSnapshotAt: echoSnapshotAt) { error in
            if error == nil { images.noteGPUCompletion() }
            onCompleted?(error)
        }
        return drawing
    }

}
