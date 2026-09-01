import CoreGraphics
import CoreText
import CortaTerminal
import Metal
import simd

/// A single point in the grid: (row, column), scrollback rows negative.
nonisolated struct GridPosition: Equatable {
    var row: Int
    var column: Int
}

/// An inclusive text selection, `start` to `end` in document order.
nonisolated struct TerminalSelection {
    var start: GridPosition
    var end: GridPosition
}

/// Turns a `Grid` snapshot into instanced quads and draws it into a given
/// rectangle — two draw calls (background, glyphs), same budget every frame
/// regardless of how much of the screen changed (`PERFORMANCE.md` §3 notes
/// damage tracking as a *CPU rebuild* optimisation, not a draw-call one; that
/// is not implemented yet and instances are rebuilt every call).
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

    init(device: MTLDevice, font: CTFont) throws {
        self.quadRenderer = try QuadRenderer(device: device)
        self.glyphAtlas = GlyphAtlas(device: device, font: font)
        self.metrics = CellMetrics(font: font)
    }

    /// Draws `grid` into `rect` of `renderPassDescriptor`. `cursorVisible`
    /// lets the shell blink the cursor without touching the grid.
    func render(
        grid: Grid,
        rect: CGRect,
        drawableSize: CGSize,
        cursorVisible: Bool,
        selection: TerminalSelection?,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        var backgroundInstances: [QuadInstance] = []
        var glyphInstances: [QuadInstance] = []
        backgroundInstances.reserveCapacity(grid.rows * grid.columns / 4 + 2)
        glyphInstances.reserveCapacity(grid.rows * grid.columns / 2)

        let cellWidth = Float(metrics.cellWidth)
        let cellHeight = Float(metrics.cellHeight)
        let baseline = Float(metrics.baselineOffset)

        for row in 0..<grid.rows {
            let line = grid.line(row)
            for column in 0..<line.count {
                let cell = line[column]
                let reversed = cell.attributes.contains(.reverse)
                let fg = TerminalColorPalette.resolveForeground(reversed ? cell.background : cell.foreground)
                let bg = TerminalColorPalette.resolveBackground(reversed ? cell.foreground : cell.background)

                let origin = SIMD2<Float>(Float(column) * cellWidth, Float(row) * cellHeight)
                if !(reversed ? cell.foreground : cell.background).isDefault || reversed {
                    backgroundInstances.append(
                        QuadInstance(origin: origin, size: .init(cellWidth, cellHeight), color: bg))
                }

                guard !cell.attributes.contains(.invisible), cell.scalar != 0x20,
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
                glyphInstances.append(
                    QuadInstance(origin: glyphOrigin, size: info.size, color: fg, uvRect: info.uvRect))
            }
        }

        if let selection {
            backgroundInstances.append(
                contentsOf: selectionQuads(
                    selection, columns: grid.columns, cellWidth: cellWidth, cellHeight: cellHeight))
        }

        if cursorVisible {
            let origin = SIMD2<Float>(
                Float(grid.cursor.column) * cellWidth, Float(grid.cursor.row) * cellHeight)
            backgroundInstances.append(
                QuadInstance(origin: origin, size: .init(cellWidth, cellHeight), color: Self.cursorColor))
        }

        quadRenderer.drawSolidQuads(
            backgroundInstances, rect: rect, drawableSize: drawableSize,
            renderPassDescriptor: renderPassDescriptor, commandBuffer: commandBuffer)
        // The glyph pass must never clear: whatever load action the caller
        // wanted has already happened for the background pass above, and a
        // second clear here would erase every background and cursor quad
        // just drawn. `MTLRenderPassDescriptor` is a reference type, so this
        // mutation is local to the two draws in this call.
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        quadRenderer.drawGlyphQuads(
            glyphInstances, atlas: glyphAtlas.texture, rect: rect, drawableSize: drawableSize,
            renderPassDescriptor: renderPassDescriptor, commandBuffer: commandBuffer)
    }

    private func selectionQuads(
        _ selection: TerminalSelection, columns: Int, cellWidth: Float, cellHeight: Float
    ) -> [QuadInstance] {
        guard selection.start.row <= selection.end.row else { return [] }
        var quads: [QuadInstance] = []
        for row in selection.start.row...selection.end.row {
            let startColumn = row == selection.start.row ? selection.start.column : 0
            let endColumn = row == selection.end.row ? selection.end.column + 1 : columns
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
