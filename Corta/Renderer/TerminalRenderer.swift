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
import simd

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
    private var captureBackend: Metal4Backend?
    let glyphAtlas: GlyphAtlas
    private struct Geometry: Sendable {
        var metrics: CellMetrics
        var points: CellMetrics
        var scale: CGFloat
    }
    private let geometry: Mutex<Geometry>
    private var metricsValue: CellMetrics
    /// Its own texture cache: images share no eviction policy with glyphs.
    let kittyImageRenderer: KittyImageRenderer
    /// Cached because `draw` takes no `Grid`.
    private var cachedImagePlacements = ImagePlacementTable()

    // MARK: - Damage-tracked instance cache

    /// Earliest time this cached grid could contain an echo. Set before snapshotting,
    /// never at submission: output may arrive while older instances are encoded.
    var echoSnapshotAt: TimeInterval?
    private var cachedLines: [Line] = []
    /// Live-screen fast path only; meaningless for rows rebuilt in history.
    private var cachedRevisions: [UInt64] = []
    private var backgroundCounts: [Int] = []
    private var glyphCounts: [Int] = []
    private var colorGlyphCounts: [Int] = []
    private var cachedBackground: ContiguousArray<QuadInstance> = []
    private var cachedGlyphs: ContiguousArray<QuadInstance> = []
    /// Their own pass: the coverage pipeline reduces emoji to a silhouette.
    private var cachedColorGlyphs: ContiguousArray<QuadInstance> = []
    private var overlayCount = 0
    private var cachedColumns = 0
    private var cachedOffset = -1
    /// Not `.count`: a full ring would look unscrolled and leave stale quads.
    private var cachedScrollbackTotalPushed = -1
    /// A swapped-in `ScreenLines` restarts revisions; see its `generation`.
    private var cachedLinesGeneration: UInt64?
    /// An OSC 4 change alters what an index resolves to, invisible to every
    /// other check.
    private var cachedIndexedOverridesGeneration: UInt64 = 0
    private var indexedOverrides: IndexedColorOverrides = [:]
    /// Journal sequence within cachedLinesGeneration, replayed in order.
    private var cachedScrollEventsTotal: UInt64 = 0
    private var cachedDocumentTop = 0
    /// Newly exposed history rows must rebuild even when their value is blank.
    private var invalidRows: [Bool] = []
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
    private struct BlockCursor: Equatable {
        var row: Int
        var column: Int
    }
    private var blockCursor: BlockCursor?
    /// Rows the damage pass rebuilds whatever their revision says: the
    /// block cursor's old and new rows. -1 is none; two `Int`s, not a set,
    /// so the per-row test allocates nothing.
    private var forcedRowA = -1
    private var forcedRowB = -1

    /// Reused, so a damaged row allocates nothing: every damaged row's new
    /// instances, back to back, with where each row's are.
    private var rowBackground: ContiguousArray<QuadInstance> = []
    private var rowGlyphs: ContiguousArray<QuadInstance> = []
    private var rowColorGlyphs: ContiguousArray<QuadInstance> = []
    private var rebuiltRows: [RebuiltRow] = []
    /// The next cache while a splice builds it, then the old one's storage.
    private var spliceBuffer: ContiguousArray<QuadInstance> = []

    /// One damaged row: its instances in the row scratch arrays, and where
    /// its old ones start in the cache.
    private struct RebuiltRow {
        var row: Int
        var background: Range<Int>
        var glyphs: Range<Int>
        var colorGlyphs: Range<Int>
        var cachedBackgroundStart: Int
        var cachedGlyphStart: Int
        var cachedColorGlyphStart: Int
    }
    private var overlayScratch: ContiguousArray<QuadInstance> = []

    /// One test rejects nearly every cell.
    private static let ruleAttributes: CellAttributes = [.underline, .strikethrough, .invisible]

    /// Secondary but readable on dark and light; zero is `invisible`'s job.
    private static let dimAlpha: Float = 0.55
    private static let colorAttributeMask = CellAttributes.reverse.rawValue | CellAttributes.dim.rawValue

    private(set) var lastRebuiltRowCount = 0

    /// This renderer's theme, instead of the live one (`TerminalColorPalette`).
    /// For tests: the live palette is process-wide, and a suite that pinned it
    /// was rendering whatever another suite had just applied.
    var themeVariant: Theme.Variant?

    /// The theme this frame's rows are built with, read once per
    /// `updateInstances` — one lock on the shared palette per frame rather
    /// than per row, and no frame half in one theme and half in the next.
    private var framePalette: Theme.Variant = Theme.corta.dark
    /// `framePalette`'s derived colours, worked out once per frame.
    private var frameOverlay = Theme.corta.dark.overlayColors
    /// The command-status rules beside prompts (`command-status-marks`).
    /// Drawn in this pass, in the left margin, so a rule shows the frame's
    /// own rows: drawn by AppKit they led the text by a frame or two and took
    /// the colour of the command below (#238).
    var drawsCommandMarks = true {
        didSet { if drawsCommandMarks != oldValue { marksAreStale = true } }
    }
    /// The rules, in the margin rect's space (`markRect`); rebuilt when the
    /// rows are, or when `drawsCommandMarks` changes.
    private var cachedMarks: ContiguousArray<QuadInstance> = []
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

    private var scaleValue: CGFloat

    public var metrics: CellMetrics { geometry.withLock { $0.metrics } }
    var pointMetrics: CellMetrics { geometry.withLock { $0.points } }
    var scale: CGFloat { geometry.withLock { $0.scale } }

    /// - Parameter scale: glyphs rasterise at `size × scale` and `metrics` are
    ///   pixels, the shader's space; 1× on a 2× display rendered half-size and
    ///   soft.
    /// - Parameter atlasPixelSize: small in tests, to exercise eviction;
    ///   `nil` is `GlyphAtlas.atlasSize`.
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

    /// Uses the very same row instances, atlas and Metal shader as the live
    /// block cursor, including wide glyphs, emoji, rules and box drawing.
    /// The small offscreen target is read only after GPU completion.
    func cursorImage(grid: Grid) -> (image: CGImage, column: Int, columns: Int)? {
        return withExclusiveAccess {
            let row = grid.cursor.row
            var column = grid.cursor.column
            guard row >= 0, row < grid.rows, column >= 0, column < grid.columns else { return nil }
            guard let line = grid.line(atAbsoluteRow: grid.scrollback.totalPushed + row) else {
                return nil
            }
            if column < line.count, line[column].attributes.contains(.wideSpacer), column > 0 {
                column -= 1
            }
            let columns = column < line.count && line[column].attributes.contains(.wide) ? 2 : 1
            let width = max(1, Int(metricsValue.cellWidth) * columns)
            let height = max(1, Int(metricsValue.cellHeight))
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.renderTarget, .shaderRead]
            if captureBackend?.requiresRecovery == true { captureBackend = nil }
            if captureBackend == nil { captureBackend = try? Metal4Backend(device: backend.device) }
            guard let target = backend.device.makeTexture(descriptor: descriptor),
                let capture = captureBackend
            else { return nil }
            let previousCursor = blockCursor
            let previousPalette = framePalette
            blockCursor = BlockCursor(row: row, column: column)
            framePalette = themeVariant ?? TerminalColorPalette.activeVariant
            defer {
                blockCursor = previousCursor
                framePalette = previousPalette
            }
            let quads = cursorCellInstances(line: line, row: row, column: column, graphemes: grid.graphemes)
            guard drawCapture(quads, into: target, with: capture, clearColor: framePalette.cursor) else { return nil }
            return Self.image(of: target).map { ($0, column, columns) }
        }
    }

    /// The cursor's row built as the live block cursor draws it, moved so
    /// the cursor's cell is at the origin.
    private func cursorCellInstances(
        line: Line, row: Int, column: Int, graphemes: GraphemeTable
    ) -> (backgrounds: ContiguousArray<QuadInstance>, glyphs: ContiguousArray<QuadInstance>,
        colors: ContiguousArray<QuadInstance>)
    {
        var backgrounds: ContiguousArray<QuadInstance> = []
        var glyphs: ContiguousArray<QuadInstance> = []
        var colors: ContiguousArray<QuadInstance> = []
        appendRowInstances(
            line: line, row: row, graphemes: graphemes,
            background: &backgrounds, glyphs: &glyphs, colorGlyphs: &colors)
        let origin = SIMD2<Float>(
            Float(column) * Float(metricsValue.cellWidth), Float(row) * Float(metricsValue.cellHeight))
        for index in backgrounds.indices { backgrounds[index].origin -= origin }
        for index in glyphs.indices { glyphs[index].origin -= origin }
        for index in colors.indices { colors[index].origin -= origin }
        return (backgrounds, glyphs, colors)
    }

    /// One frame of `quads` into `target` on the capture queue, waited for.
    private func drawCapture(
        _ quads: (backgrounds: ContiguousArray<QuadInstance>, glyphs: ContiguousArray<QuadInstance>,
            colors: ContiguousArray<QuadInstance>),
        into target: MTLTexture, with capture: Metal4Backend, clearColor color: SIMD4<Float>
    ) -> Bool {
        let size = CGSize(width: target.width, height: target.height)
        let rect = CGRect(origin: .zero, size: size)
        guard
            capture.beginFrame(
                target: target,
                clearColor: MTLClearColorMake(Double(color.x), Double(color.y), Double(color.z), 1),
                label: "Corta.cursor.capture")
        else { return false }
        capture.drawSolidQuads(quads.backgrounds, rect: rect, drawableSize: size)
        capture.drawGlyphQuads(
            quads.glyphs, atlas: glyphAtlas.texture, atlasRects: glyphAtlas.atlasRects,
            atlasRectsVersion: glyphAtlas.atlasRectsVersion,
            rect: rect, drawableSize: size)
        capture.drawColorQuads(
            quads.colors, atlas: glyphAtlas.colorTexture, atlasRects: glyphAtlas.atlasRects,
            atlasRectsVersion: glyphAtlas.atlasRectsVersion,
            rect: rect, drawableSize: size)
        let done = DispatchSemaphore(value: 0)
        let succeeded = Atomic<Bool>(false)
        capture.endFrame(presenting: nil) { error in
            succeeded.store(error == nil, ordering: .releasing)
            done.signal()
        }
        return done.wait(timeout: .now() + 2) == .success && succeeded.load(ordering: .acquiring)
    }

    /// A finished `bgra8Unorm` target's pixels as an sRGB image.
    private static func image(of target: MTLTexture) -> CGImage? {
        let width = target.width
        let height = target.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            target.getBytes(
                $0.baseAddress!, bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                .union(.byteOrder32Little), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)
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

        var changed = fullRebuild
        var rowsChanged = fullRebuild
        let previousBlockCursor = blockCursor
        let isBlock = effectiveCursorStyle == .block || effectiveCursorStyle == .blinkingBlock
        blockCursor =
            isBlock && cursorVisible && offset == 0
            ? BlockCursor(row: grid.cursor.row, column: grid.cursor.column) : nil
        // An eviction mid-build stales every UV: rebuild once. Content that alone
        // overflows the atlas draws blank.
        let atlasGeneration = glyphAtlas.generation
        glyphAtlas.beginFrame(shapingBudget: Self.shapingBudgetPerFrame)
        if fullRebuild {
            rebuildAllRows(grid: grid, offset: offset)
        } else {
            changed = rebuildDamagedRows(
                grid: grid, offset: offset, previousBlockCursor: previousBlockCursor)
            rowsChanged = changed
        }
        if glyphAtlas.generation != atlasGeneration {
            rebuildAllRows(grid: grid, offset: offset)
            changed = true
            rowsChanged = true
        }

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

        // Decodes are scheduled here, never in `draw`; an image delete changes
        // no cell, so it registers as damage here or not at all.
        if cachedImagePlacements.revision != grid.imagePlacements.revision {
            changed = true
        }
        kittyImageRenderer.update(
            table: grid.imagePlacements, rows: grid.rows, offset: offset,
            scrollbackTotalPushed: grid.scrollback.totalPushed,
            cellWidth: Float(metricsValue.cellWidth), cellHeight: Float(metricsValue.cellHeight))
        remember(
            grid: grid, offset: offset, indexedOverridesGeneration: indexedOverridesGeneration,
            cursorStyle: effectiveCursorStyle, cursorVisible: cursorVisible, selection: selection,
            searchMatches: searchMatches, currentSearchMatchIndex: currentSearchMatchIndex,
            hoveredLink: hoveredLink)
        // Rows that drew without some glyph are rebuilt next frame. Asked for
        // only while nothing was evicted: past that the content overflows the
        // atlas, and re-asking would shape a budget's worth every frame for as
        // long as it stays on screen.
        needsFullRebuild = glyphAtlas.deferredShaping && glyphAtlas.generation == atlasGeneration
        if needsFullRebuild {
            onGlyphsDeferred?()
        }
        // Not on a cursor blink or a selection drag: only the rows carry marks.
        if rowsChanged || marksAreStale {
            changed = changed || marksAreStale
            rebuildMarks(alternateScreen: grid.isAlternateScreenActive)
            marksAreStale = false
        }
        return changed
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

    private func rebuildAllRows(grid: Grid, offset: Int) {
        cachedBackground.removeAll(keepingCapacity: true)
        cachedGlyphs.removeAll(keepingCapacity: true)
        cachedColorGlyphs.removeAll(keepingCapacity: true)
        backgroundCounts.removeAll(keepingCapacity: true)
        glyphCounts.removeAll(keepingCapacity: true)
        colorGlyphCounts.removeAll(keepingCapacity: true)
        cachedLines.removeAll(keepingCapacity: true)
        cachedRevisions.removeAll(keepingCapacity: true)
        cachedBackground.reserveCapacity(grid.rows * grid.columns / 4 + 2)
        cachedGlyphs.reserveCapacity(grid.rows * grid.columns / 2)
        let liveScreen = offset == 0
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
            cachedRevisions.append(liveScreen ? grid.lineRevision(row) : 0)
        }
        overlayCount = 0
        invalidRows.removeAll(keepingCapacity: true)
        invalidRows.append(contentsOf: repeatElement(false, count: grid.rows))
        lastRebuiltRowCount = grid.rows
    }

    /// Line-granular damage: rebuild only the rows that changed into the
    /// scratch arrays, then put them in the cache (`place`), so a frame
    /// that damages every row costs one pass over the cache, not one per
    /// row.
    ///
    /// The live screen (`offset == 0`) is checked with `Grid.lineRevision`,
    /// a single `UInt64` compare, instead of a full `Line` comparison —
    /// see the type's doc comment and
    /// `ScreenLines.swift`. Scrolled into history, rows are immutable
    /// scrollback storage with no revision to compare. Retained history rows
    /// compare only their mutable mark; live/history transitions and the live
    /// portion of a partly scrolled viewport still compare cells by value.
    private func rebuildDamagedRows(
        grid: Grid, offset: Int, previousBlockCursor: BlockCursor?
    ) -> Bool {
        let liveScreen = offset == 0
        let moved = shiftRetainedRows(grid: grid, offset: offset, previousBlockCursor: previousBlockCursor)
        forcedRowA = -1
        forcedRowB = -1
        if previousBlockCursor != blockCursor || moved.shifted {
            forcedRowA = moved.oldCursorRow
            forcedRowB = blockCursor?.row ?? -1
        }
        rowBackground.removeAll(keepingCapacity: true)
        rowGlyphs.removeAll(keepingCapacity: true)
        rowColorGlyphs.removeAll(keepingCapacity: true)
        rebuiltRows.removeAll(keepingCapacity: true)
        var backgroundStart = 0
        var glyphStart = 0
        var colorGlyphStart = 0
        for row in 0..<grid.rows {
            let revision = liveScreen ? grid.lineRevision(row) : 0
            let forced = row == forcedRowA || row == forcedRowB
            // Retained history cells never change; only marks can be edited.
            // A formerly live row may have changed before entering history,
            // so compare that transition by value rather than assuming it froze.
            let unchangedHistory = !liveScreen && row < offset && row < moved.retainedHistoryRows
                && !invalidRows[row]
                && grid.scrollback.mark(at: grid.scrollback.count - offset + row) == cachedLines[row].mark
            let possiblyChanged = forced || invalidRows[row]
                || (liveScreen ? revision != cachedRevisions[row] : !unchangedHistory)
            if possiblyChanged {
                let line = Self.visibleLine(grid: grid, row: row, offset: offset)
                if liveScreen || forced || invalidRows[row] || line != cachedLines[row] {
                    rebuildRow(
                        row, line: line, revision: revision, graphemes: grid.graphemes,
                        cachedStarts: (backgroundStart, glyphStart, colorGlyphStart))
                }
            }
            backgroundStart += backgroundCounts[row]
            glyphStart += glyphCounts[row]
            colorGlyphStart += colorGlyphCounts[row]
        }
        lastRebuiltRowCount = rebuiltRows.count
        guard !rebuiltRows.isEmpty else { return moved.shifted }
        place(
            into: &cachedBackground, counts: &backgroundCounts, from: rowBackground,
            ranges: \.background, starts: \.cachedBackgroundStart)
        place(
            into: &cachedGlyphs, counts: &glyphCounts, from: rowGlyphs, ranges: \.glyphs,
            starts: \.cachedGlyphStart)
        place(
            into: &cachedColorGlyphs, counts: &colorGlyphCounts, from: rowColorGlyphs,
            ranges: \.colorGlyphs, starts: \.cachedColorGlyphStart)
        return true
    }

    /// Moves the cached rows the way the screen moved since the last frame:
    /// the live screen replays the scroll journal, a viewport into history
    /// shifts by how far its document top moved. Returns where the old block
    /// cursor's row went (`-1` once it scrolled out) and how many retained
    /// history rows are still on screen.
    private func shiftRetainedRows(
        grid: Grid, offset: Int, previousBlockCursor: BlockCursor?
    ) -> (shifted: Bool, oldCursorRow: Int, retainedHistoryRows: Int) {
        var shifted = false
        var retainedHistoryRows = min(grid.rows, max(0, cachedOffset))
        var oldCursorRow = previousBlockCursor?.row ?? -1
        func shift(top: Int, bottom: Int, delta: Int) {
            applyShift(top: top, bottom: bottom, delta: delta, cellHeight: Float(metricsValue.cellHeight))
            shifted = true
            if oldCursorRow >= top && oldCursorRow <= bottom {
                oldCursorRow -= delta
                if oldCursorRow < top || oldCursorRow > bottom { oldCursorRow = -1 }
            }
        }
        if offset == 0 && cachedOffset == 0 {
            // Overflow: ordinary revision comparison remains correct; old cached
            // rows have not moved, so the old cursor also remains in its old row.
            guard grid.scrollEventsTotal >= cachedScrollEventsTotal,
                grid.scrollEventsTotal - cachedScrollEventsTotal <= UInt64(Grid.scrollEventCapacity)
            else { return (shifted, oldCursorRow, retainedHistoryRows) }
            // A region flood logs a line per event: same region, same
            // direction, the shifts add up, so each run moves once.
            var run: (top: Int, bottom: Int, delta: Int)?
            for sequence in cachedScrollEventsTotal..<grid.scrollEventsTotal {
                guard let event = grid.scrollEvent(at: sequence) else { continue }
                let next = (top: Int(event.top), bottom: Int(event.bottom), delta: Int(event.delta))
                if let pending = run, pending.top == next.top, pending.bottom == next.bottom,
                    (pending.delta > 0) == (next.delta > 0)
                {
                    run?.delta += next.delta
                    continue
                }
                if let pending = run { shift(top: pending.top, bottom: pending.bottom, delta: pending.delta) }
                run = next
            }
            if let pending = run { shift(top: pending.top, bottom: pending.bottom, delta: pending.delta) }
        } else {
            let delta = grid.scrollback.totalPushed - offset - cachedDocumentTop
            if delta != 0 {
                shift(top: 0, bottom: grid.rows - 1, delta: delta)
                retainedHistoryRows = max(0, min(grid.rows, retainedHistoryRows - delta))
            }
        }
        return (shifted, oldCursorRow, retainedHistoryRows)
    }

    /// Builds one row's instances into the scratch arrays and records where
    /// they go in the cache.
    private func rebuildRow(
        _ row: Int, line: Line, revision: UInt64, graphemes: GraphemeTable,
        cachedStarts: (background: Int, glyphs: Int, colorGlyphs: Int)
    ) {
        let starts = (rowBackground.count, rowGlyphs.count, rowColorGlyphs.count)
        appendRowInstances(
            line: line, row: row, graphemes: graphemes,
            background: &rowBackground, glyphs: &rowGlyphs, colorGlyphs: &rowColorGlyphs)
        rebuiltRows.append(
            RebuiltRow(
                row: row, background: starts.0..<rowBackground.count,
                glyphs: starts.1..<rowGlyphs.count, colorGlyphs: starts.2..<rowColorGlyphs.count,
                cachedBackgroundStart: cachedStarts.background, cachedGlyphStart: cachedStarts.glyphs,
                cachedColorGlyphStart: cachedStarts.colorGlyphs))
        cachedLines[row] = line
        cachedRevisions[row] = revision
        invalidRows[row] = false
    }

    /// Puts the rebuilt rows' instances from `scratch` into `cached`, the
    /// cheaper of two ways. In place, row by row, a row whose count changed
    /// moves everything after it — nothing for typing, the overlay alone for
    /// a scroll's new bottom row, but every instance once per row when a
    /// flood or a redrawing TUI changes them all. Past one array's worth of
    /// moves, the array is rebuilt in one pass instead: unchanged rows
    /// copied from the cache, rebuilt ones from `scratch`, then whatever
    /// follows the rows (the background's overlay). `counts` becomes the
    /// new per-row counts either way.
    private func place(
        into cached: inout ContiguousArray<QuadInstance>, counts: inout [Int], from scratch: ContiguousArray<QuadInstance>,
        ranges: KeyPath<RebuiltRow, Range<Int>>, starts: KeyPath<RebuiltRow, Int>
    ) {
        var moves = 0
        for rebuilt in rebuiltRows where rebuilt[keyPath: ranges].count != counts[rebuilt.row] {
            moves += cached.count - rebuilt[keyPath: starts] - counts[rebuilt.row]
        }
        if moves <= cached.count {
            var shift = 0
            for rebuilt in rebuiltRows {
                let range = rebuilt[keyPath: ranges]
                let start = rebuilt[keyPath: starts] + shift
                cached.replaceSubrange(start..<(start + counts[rebuilt.row]), with: scratch[range])
                shift += range.count - counts[rebuilt.row]
                counts[rebuilt.row] = range.count
            }
            return
        }
        spliceBuffer.removeAll(keepingCapacity: true)
        spliceBuffer.reserveCapacity(cached.count + scratch.count)
        var source = 0
        var next = 0
        for row in counts.indices {
            let count = counts[row]
            if next < rebuiltRows.count, rebuiltRows[next].row == row {
                let range = rebuiltRows[next][keyPath: ranges]
                spliceBuffer.append(contentsOf: scratch[range])
                counts[row] = range.count
                next += 1
            } else {
                spliceBuffer.append(contentsOf: cached[source..<(source + count)])
            }
            source += count
        }
        spliceBuffer.append(contentsOf: cached[source...])
        swap(&cached, &spliceBuffer)
    }

    /// Retained instances keep their atlas coordinates and move only in Y.
    /// Exposed rows are invalidated; overlays outside the region stay fixed.
    private func applyShift(top: Int, bottom: Int, delta: Int, cellHeight: Float) {
        guard delta != 0 else { return }
        let height = bottom - top + 1
        let count = min(abs(delta), height)
        let retained = delta > 0 ? (top + count)..<(bottom + 1) : top..<(bottom - count + 1)
        let shiftY = Float(delta) * cellHeight
        func moveInstances(_ instances: inout ContiguousArray<QuadInstance>, counts: inout [Int]) {
            let regionStart = counts[..<top].reduce(0, +)
            let regionEnd = regionStart + counts[top...bottom].reduce(0, +)
            let keptStart = counts[..<retained.lowerBound].reduce(0, +)
            let keptEnd = keptStart + counts[retained].reduce(0, +)
            // Delete the discarded ends in place. The overlay tail is outside
            // regionEnd and never moves in Y, even when its array index changes.
            instances.removeSubrange(keptEnd..<regionEnd)
            instances.removeSubrange(regionStart..<keptStart)
            for i in regionStart..<(regionStart + keptEnd - keptStart) {
                instances[i].origin.y -= shiftY
            }
            if delta > 0 {
                for row in top..<(bottom - count + 1) { counts[row] = counts[row + count] }
                for row in (bottom - count + 1)...bottom { counts[row] = 0 }
            } else {
                for row in stride(from: bottom, through: top + count, by: -1) { counts[row] = counts[row - count] }
                for row in top..<(top + count) { counts[row] = 0 }
            }
        }
        moveInstances(&cachedBackground, counts: &backgroundCounts)
        moveInstances(&cachedGlyphs, counts: &glyphCounts)
        moveInstances(&cachedColorGlyphs, counts: &colorGlyphCounts)
        if delta > 0 {
            for row in top..<(bottom - count + 1) {
                cachedLines[row] = cachedLines[row + count]
                cachedRevisions[row] = cachedRevisions[row + count]
                invalidRows[row] = invalidRows[row + count]
            }
        } else {
            for row in stride(from: bottom, through: top + count, by: -1) {
                cachedLines[row] = cachedLines[row - count]
                cachedRevisions[row] = cachedRevisions[row - count]
                invalidRows[row] = invalidRows[row - count]
            }
        }
        let exposed = delta > 0 ? (bottom - count + 1)...bottom : top...(top + count - 1)
        for row in exposed {
            cachedLines[row] = Line()
            cachedRevisions[row] = .max
            invalidRows[row] = true
        }
    }

    private func rebuildOverlay(
        grid: Grid, cursorStyle: CursorStyle, cursorVisible: Bool, selection: TerminalSelection?, offset: Int,
        searchMatches: [TerminalSelection] = [], currentSearchMatchIndex: Int? = nil,
        hoveredLink: TerminalSelection? = nil
    ) {
        let cellWidth = Float(metricsValue.cellWidth)
        let cellHeight = Float(metricsValue.cellHeight)
        overlayScratch.removeAll(keepingCapacity: true)
        if let selection {
            overlayScratch.append(
                contentsOf: selectionQuads(
                    selection, grid: grid, offset: offset, cellWidth: cellWidth, cellHeight: cellHeight,
                    color: frameOverlay.selection))
        }
        // After the selection, before the cursor, which stays on top.
        for (index, match) in searchMatches.enumerated() {
            overlayScratch.append(
                contentsOf: selectionQuads(
                    match, grid: grid, offset: offset, cellWidth: cellWidth, cellHeight: cellHeight,
                    color: index == currentSearchMatchIndex
                        ? frameOverlay.currentSearchMatch : frameOverlay.searchMatch))
        }
        // A rule, not a fill: it must read as a link and not fight the
        // selection.
        if let hoveredLink {
            for quad in selectionQuads(
                hoveredLink, grid: grid, offset: offset, cellWidth: cellWidth,
                cellHeight: cellHeight, color: frameOverlay.linkUnderline)
            {
                let thickness = max(1, Float(scaleValue).rounded(.down))
                overlayScratch.append(
                    QuadInstance(
                        origin: .init(quad.origin.x, quad.origin.y + cellHeight - thickness * 2),
                        size: .init(quad.size.x, thickness), color: quad.color))
            }
        }
        // A block cursor is drawn by its row (`appendRowInstances`).
        if cursorVisible, blockCursor == nil {
            let cellOrigin = SIMD2<Float>(
                Float(grid.cursor.column) * cellWidth, Float(grid.cursor.row) * cellHeight)
            // An eighth of a cell, at least 2 device pixels.
            let stroke = max(2, (cellHeight / 8).rounded(.down))
            let cursorColor = framePalette.cursor
            switch cursorStyle {
            case .block, .blinkingBlock:
                break  // Only off the live screen, where no cursor is drawn.
            case .underline, .blinkingUnderline:
                overlayScratch.append(
                    QuadInstance(
                        origin: .init(cellOrigin.x, cellOrigin.y + cellHeight - stroke),
                        size: .init(cellWidth, stroke), color: cursorColor))
            case .bar, .blinkingBar:
                overlayScratch.append(
                    QuadInstance(
                        origin: cellOrigin, size: .init(stroke, cellHeight), color: cursorColor))
            }
        }
        let end = cachedBackground.count
        cachedBackground.replaceSubrange((end - overlayCount)..<end, with: overlayScratch)
        overlayCount = overlayScratch.count
    }

    /// The per-cell loop, for damaged rows only. A wide glyph is scaled to fit
    /// its two-cell box — the CJK fallback font is never exactly two advances
    /// wide; a side-table cluster is shaped as one run into the same box.
    private func appendRowInstances(
        line: Line, row: Int, graphemes: GraphemeTable,
        background: inout ContiguousArray<QuadInstance>, glyphs: inout ContiguousArray<QuadInstance>,
        colorGlyphs: inout ContiguousArray<QuadInstance>
    ) {
        let cell = SIMD2<Float>(Float(metricsValue.cellWidth), Float(metricsValue.cellHeight))
        // Once per row: the property retains the ANSI array on every touch.
        let palette = framePalette
        let cursor = blockCursorColumns(in: line, row: row, cell: cell, palette: palette, into: &background)
        var colors = CellColors()
        for column in 0..<line.count {
            let current = line[column]
            let attributes = current.attributes
            let underCursor = cursor.contains(column)
            colors.update(for: current, underCursor: underCursor, palette: palette, overrides: indexedOverrides)
            let origin = SIMD2<Float>(Float(column) * cell.x, Float(row) * cell.y)
            let reversed = attributes.contains(.reverse)
            if underCursor || !(reversed ? current.foreground : current.background).isDefault || reversed {
                background.append(QuadInstance(origin: origin, size: cell, rgba: colors.packedBackground))
            }
            appendRules(for: current, at: origin, cell: cell, color: colors.foreground, into: &background)
            guard !attributes.contains(.invisible), !attributes.contains(.wideSpacer) else { continue }
            if appendGeometry(for: current.scalar, at: origin, cell: cell, colors: colors, into: &background) {
                continue
            }
            let found: GlyphAtlas.GlyphInfo?
            if current.grapheme.isNone, current.scalar < 0x80 {
                // The common case stays in the loop: an index into the ASCII table.
                found = current.scalar == 0x20 ? nil : glyphAtlas.glyph(forASCII: current.scalar, style: Self.style(of: attributes))
            } else {
                found = glyph(for: current, graphemes: graphemes)
            }
            guard let info = found else { continue }
            let isWide = attributes.contains(.wide)
            // No font covers it: a hollow box, not a silent gap.
            if info.isMissing {
                appendMissingGlyphBox(
                    at: origin, cellWidth: cell.x * (isWide ? 2 : 1), cellHeight: cell.y,
                    color: colors.foreground, into: &background)
                continue
            }
            guard info.size != .zero else { continue }
            let instance = placed(info, at: origin, cell: cell, wide: isWide, rgba: colors.packedForeground)
            // Color glyphs go to the color pass; coverage would flatten them.
            if info.isColor {
                colorGlyphs.append(instance)
            } else {
                glyphs.append(instance)
            }
        }
    }

    /// The colours a cell draws with. Raw roles, colour rendition bits and
    /// cursor coverage fully determine both, so they are resolved again only
    /// when those change: two integer words compared per cell instead of
    /// eight Float lanes.
    private struct CellColors {
        private var key = SIMD2<UInt64>(repeating: .max)
        private(set) var foreground = SIMD4<Float>.zero
        private(set) var background = SIMD4<Float>.zero
        private(set) var packedForeground: UInt32 = 0
        private(set) var packedBackground: UInt32 = 0

        @inline(__always)
        mutating func update(
            for cell: Cell, underCursor: Bool, palette: Theme.Variant, overrides: IndexedColorOverrides
        ) {
            let attributes = cell.attributes
            let key = SIMD2<UInt64>(
                UInt64(cell.foreground.rawValue) << 32 | UInt64(cell.background.rawValue),
                UInt64(attributes.rawValue & TerminalRenderer.colorAttributeMask) << 1 | (underCursor ? 1 : 0))
            guard key != self.key else { return }
            self.key = key
            // Resolve roles before reversing: the two default roles differ.
            let resolvedFg = palette.resolveForeground(cell.foreground, indexedOverrides: overrides)
            let resolvedBg = palette.resolveBackground(cell.background, indexedOverrides: overrides)
            let reversed = attributes.contains(.reverse)
            foreground = reversed ? resolvedBg : resolvedFg
            background = reversed ? resolvedFg : resolvedBg
            if attributes.contains(.dim) { foreground.w *= TerminalRenderer.dimAlpha }
            if underCursor {
                foreground = palette.background
                background = palette.cursor
            }
            packedForeground = QuadInstance.packColor(foreground)
            packedBackground = QuadInstance.packColor(background)
        }
    }

    /// The block cursor's columns in this row — two under a wide character,
    /// so the whole glyph inverts — or an empty range. Past the line's
    /// stored cells there is no character to invert: one cursor-coloured
    /// cell, appended here.
    @inline(__always)
    private func blockCursorColumns(
        in line: Line, row: Int, cell: SIMD2<Float>, palette: Theme.Variant,
        into background: inout ContiguousArray<QuadInstance>
    ) -> Range<Int> {
        guard let blockCursor, blockCursor.row == row else { return 0..<0 }
        guard blockCursor.column < line.count else {
            background.append(
                QuadInstance(
                    origin: .init(Float(blockCursor.column) * cell.x, Float(row) * cell.y),
                    size: cell, color: palette.cursor))
            return 0..<0
        }
        var start = blockCursor.column
        var end = start + 1
        let attributes = line[start].attributes
        if attributes.contains(.wide) {
            end += 1
        } else if attributes.contains(.wideSpacer), start > 0 {
            // On the right half (a CUP or one BS can land there).
            start -= 1
        }
        return start..<end
    }

    /// Underline and strikethrough: rules, not glyphs. An OSC 8 link is
    /// always underlined — `ls --hyperlink` sets no rendition. A spacer
    /// draws them too, so they span a wide character.
    @inline(__always)
    private func appendRules(
        for cell: Cell, at origin: SIMD2<Float>, cell size: SIMD2<Float>, color: SIMD4<Float>,
        into background: inout ContiguousArray<QuadInstance>
    ) {
        let attributes = cell.attributes
        // One test for the group, the common case.
        guard !attributes.isDisjoint(with: Self.ruleAttributes) || !cell.hyperlink.isNone,
            !attributes.contains(.invisible)
        else { return }
        let baseline = Float(metricsValue.baselineOffset)
        let thickness = max(1, Float(scaleValue).rounded(.down))
        if attributes.contains(.underline) || !cell.hyperlink.isNone {
            background.append(
                QuadInstance(
                    origin: .init(origin.x, origin.y + baseline + thickness),
                    size: .init(size.x, thickness), color: color))
        }
        if attributes.contains(.strikethrough) {
            background.append(
                QuadInstance(
                    // Roughly mid x-height; the real metric is per font.
                    origin: .init(origin.x, origin.y + baseline * 0.7),
                    size: .init(size.x, thickness), color: color))
        }
    }

    /// Box drawing and block elements as geometry, not glyphs: glyphs fall
    /// short of rounded-up cells and leave a grid of gaps between them
    /// (`BlockElements`). False for any other scalar.
    @inline(__always)
    private func appendGeometry(
        for scalar: UInt32, at origin: SIMD2<Float>, cell: SIMD2<Float>, colors: CellColors,
        into background: inout ContiguousArray<QuadInstance>
    ) -> Bool {
        let fg = colors.foreground
        if scalar >= 0x2500, scalar <= 0x257F,
            let pieces = BoxDrawing.pieces(for: scalar, width: cell.x, height: cell.y, scale: Float(scaleValue))
        {
            // Stroke arms overlap at junctions. Resolve faint text over its
            // cell background once, so overlap cannot brighten it.
            let bg = colors.background
            let stroke = SIMD4<Float>(
                fg.x * fg.w + bg.x * (1 - fg.w),
                fg.y * fg.w + bg.y * (1 - fg.w),
                fg.z * fg.w + bg.z * (1 - fg.w), 1)
            for piece in pieces {
                background.append(QuadInstance(
                    origin: .init(origin.x + piece.x, origin.y + piece.y),
                    size: .init(piece.z, piece.w), color: stroke))
            }
            return true
        }
        guard let pieces = BlockElements.pieces(for: scalar) else { return false }
        for piece in pieces {
            background.append(
                QuadInstance(
                    origin: .init(origin.x + piece.rect.x * cell.x, origin.y + piece.rect.y * cell.y),
                    size: .init(piece.rect.z * cell.x, piece.rect.w * cell.y),
                    color: .init(fg.x, fg.y, fg.z, fg.w * piece.alpha)))
        }
        return true
    }

    @inline(__always)
    private static func style(of attributes: CellAttributes) -> GlyphAtlas.Style {
        GlyphAtlas.Style(bold: attributes.contains(.bold), italic: attributes.contains(.italic))
    }

    /// The atlas entry a cell outside the ASCII fast path draws, or `nil`
    /// for a blank cell or one the atlas cannot hold this frame.
    private func glyph(for cell: Cell, graphemes: GraphemeTable) -> GlyphAtlas.GlyphInfo? {
        let style = Self.style(of: cell.attributes)
        // Even on a space base: a combining mark can attach to one.
        if !cell.grapheme.isNone, let scalars = graphemes.scalars(for: cell.grapheme) {
            return glyphAtlas.glyph(forCluster: scalars, style: style)
        }
        guard cell.scalar != 0x20, let scalar = Unicode.Scalar(cell.scalar) else { return nil }
        return scalar.isASCII
            ? glyphAtlas.glyph(forASCII: cell.scalar, style: style)
            : glyphAtlas.glyph(shaping: cell.scalar, style: style)
    }

    /// A glyph's quad, its ink fitted to the cell box.
    @inline(__always)
    private func placed(
        _ info: GlyphAtlas.GlyphInfo, at origin: SIMD2<Float>, cell: SIMD2<Float>, wide: Bool, rgba: UInt32
    ) -> QuadInstance {
        let baseline = Float(metricsValue.baselineOffset)
        var glyphOrigin = SIMD2<Float>(
            origin.x + info.bearing.x,
            origin.y + baseline - info.bearing.y - info.size.y
        )
        var glyphSize = info.size
        let boxWidth = wide ? cell.x * 2 : cell.x
        // Fit every glyph's ink to its box, not just wide ones: a bold face a
        // shade wider, or a font monospaced for letters only, spills into the
        // next column and nothing clips it. One device pixel of tolerance keeps
        // ordinary text on the fast path.
        let ink = info.size.x - 2 * GlyphAtlas.bitmapPadding
        if info.isColor {
            let placed = Self.colorGlyphPlacement(
                info, cellOrigin: origin, boxWidth: boxWidth, cellHeight: cell.y)
            glyphOrigin = placed.origin
            glyphSize = placed.size
        } else if wide || ink > boxWidth + 1 {
            // Down, never up; centred; the baseline keeps it on the line.
            let fit = min(1, boxWidth / info.size.x, cell.y / info.size.y)
            glyphSize = info.size * fit
            glyphOrigin = SIMD2<Float>(
                origin.x + (boxWidth - glyphSize.x) / 2,
                origin.y + baseline - (info.bearing.y + info.size.y) * fit
            )
        } else {
            // Pixel-aligned: sampling at a fractional origin filters Core Text's
            // antialiasing twice and softens 12pt text.
            glyphOrigin.x = glyphOrigin.x.rounded()
            glyphOrigin.y = glyphOrigin.y.rounded()
        }
        return QuadInstance(origin: glyphOrigin, size: glyphSize, rgba: rgba, atlasIndex: info.atlasIndex)
    }

    /// Where a color glyph's quad goes in its box. The atlas drew it to fit
    /// two cells, so in a two-cell box it maps texel for texel; only a box
    /// the grid narrowed to one cell scales it down. Centred, on whole pixels:
    /// a bitmap sampled at a fractional origin blurs.
    static func colorGlyphPlacement(
        _ info: GlyphAtlas.GlyphInfo, cellOrigin: SIMD2<Float>, boxWidth: Float, cellHeight: Float
    ) -> (origin: SIMD2<Float>, size: SIMD2<Float>) {
        let scale = min(1, boxWidth / max(info.size.x, 1), cellHeight / max(info.size.y, 1))
        let size = info.size * scale
        return (
            SIMD2<Float>(
                (cellOrigin.x + (boxWidth - size.x) / 2).rounded(.down),
                (cellOrigin.y + (cellHeight - size.y) / 2).rounded(.down)),
            size
        )
    }

    /// Inset so a run of them reads as boxes, not a grid.
    private func appendMissingGlyphBox(
        at origin: SIMD2<Float>, cellWidth: Float, cellHeight: Float, color: SIMD4<Float>,
        into background: inout ContiguousArray<QuadInstance>
    ) {
        let thickness = max(1, Float(scaleValue).rounded(.down))
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

    /// The rule's column (`TerminalLayout.statusRuleOffset`, `Width`), in
    /// the inset — never over a cell. As tall as the grid.
    func markRect(beside rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - TerminalLayout.statusRuleOffset * scaleValue, y: rect.minY,
            width: TerminalLayout.statusRuleWidth * scaleValue, height: rect.height)
    }

    /// One rule per prompt row with an outcome, from the rows this frame
    /// draws: 2 points shorter than the row at each end, so neighbouring
    /// prompts' rules stay apart. An interruption is the rule split in two
    /// around its middle — a gap of 4 points.
    private func rebuildMarks(alternateScreen: Bool) {
        cachedMarks.removeAll(keepingCapacity: true)
        guard drawsCommandMarks, !alternateScreen else { return }
        let cellHeight = Float(metricsValue.cellHeight)
        let point = Float(scaleValue)
        let width = Float(TerminalLayout.statusRuleWidth) * point
        // At least a point, however small the font.
        let height = max(point, cellHeight - 4 * point)
        for row in cachedLines.indices {
            let mark = cachedLines[row].mark
            guard mark.hasOutcome else { continue }
            let color = Self.markColor(mark, frameOverlay)
            let top = Float(row) * cellHeight + 2 * point
            if mark == .promptInterrupted {
                let half = max(point, height / 2 - 2 * point)
                cachedMarks.append(
                    QuadInstance(origin: .init(0, top), size: .init(width, half), color: color))
                cachedMarks.append(
                    QuadInstance(
                        origin: .init(0, top + height / 2 + 2 * point), size: .init(width, half),
                        color: color))
            } else {
                cachedMarks.append(
                    QuadInstance(origin: .init(0, top), size: .init(width, height), color: color))
            }
        }
    }

    /// Only an outcome is drawn (the caller's test). A prompt whose command
    /// has not reported — always the current one — and an output-start row
    /// carry nothing a reader can use, and after `clear` a grey rule on the
    /// lone prompt read as a rendering artefact (#165).
    private static func markColor(_ mark: LineMark, _ overlay: OverlayColors) -> SIMD4<Float> {
        if mark == .promptInterrupted { return overlay.markInterrupted }
        return mark == .promptFailed ? overlay.markFailed : overlay.markSucceeded
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

    /// Scrollback and the live screen as one contiguous array.
    private static func visibleLine(grid: Grid, row: Int, offset: Int) -> Line {
        guard offset > 0 else { return grid.line(row) }
        let combinedIndex = grid.scrollback.count + row - offset
        if combinedIndex < grid.scrollback.count {
            return grid.scrollback[combinedIndex]
        }
        return grid.line(combinedIndex - grid.scrollback.count)
    }

    /// Shifted by scrollback growth since recording, then by the scroll
    /// offset; rows off screen produce nothing.
    private func selectionQuads(
        _ selection: TerminalSelection, grid: Grid, offset: Int, cellWidth: Float, cellHeight: Float,
        color: SIMD4<Float>
    ) -> ContiguousArray<QuadInstance> {
        guard selection.start.row <= selection.end.row else { return [] }
        // `totalPushed`, as the copy path uses — `.count` let the highlight and
        // the copied text disagree once the ring filled.
        let firstRow =
            ScrollbackCoordinates.reanchoredRow(
                selection.start.row, from: selection.baseScrollbackTotal,
                to: grid.scrollback.totalPushed) + offset
        let lastRow =
            ScrollbackCoordinates.reanchoredRow(
                selection.end.row, from: selection.baseScrollbackTotal,
                to: grid.scrollback.totalPushed) + offset
        guard lastRow >= 0, firstRow < grid.rows else { return [] }
        var quads: ContiguousArray<QuadInstance> = []
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
