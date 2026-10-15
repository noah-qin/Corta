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

import CortaTerminal
import Foundation
import simd

/// One row's cells as quad instances: colours, rules, block geometry and glyphs.
nonisolated extension TerminalRenderer {
    /// The per-cell loop, for damaged rows only. A wide glyph is scaled to fit
    /// its two-cell box — the CJK fallback font is never exactly two advances
    /// wide; a side-table cluster is shaped as one run into the same box.
    func appendRowInstances(
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
}
