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
import CortaTerminal
import Metal
import Testing

@testable import Corta

/// `SGR 4:n` and `21`, drawn: one rule, two, or a wave.
@Suite(.serialized, .metalSerialized, .enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
struct UnderlineStyleRenderTests {
    /// The rows of column `x` that carry ink, as runs of consecutive rows.
    private static func inkRuns(in texture: MTLTexture, x: Int, height: Int) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        for y in 0..<height where MetalRenderTarget.pixel(of: texture, x: x, y: y).r > 60 {
            if let last = runs.last, last.upperBound == y - 1 { runs[runs.count - 1] = last.lowerBound...y } else { runs.append(y...y) }
        }
        return runs
    }

    @Test("single is one rule, double two, curly a wave")
    func stylesDraw() throws {
        guard let fixture = try RenderFixture(columns: 9, rows: 1) else {
            Issue.record("No Metal device available in this environment")
            return
        }
        // Light rules on the black clear colour, whatever the host's appearance.
        fixture.renderer.themeVariant = Theme.corta.dark
        var terminal = Terminal(rows: 1, columns: 9)
        // Spaces carry the rules without a glyph in the way.
        terminal.feed(Array("\u{1B}[4m   \u{1B}[0m\u{1B}[21m   \u{1B}[0m\u{1B}[4:3m   \u{1B}[0m".utf8))
        let texture = MetalRenderTarget.make(
            device: fixture.renderer.backend.device, width: fixture.width, height: fixture.height)
        fixture.renderer.renderAndWait(
            grid: terminal.grid, rect: CGRect(x: 0, y: 0, width: fixture.width, height: fixture.height),
            drawableSize: CGSize(width: fixture.width, height: fixture.height),
            cursorVisible: false, selection: nil, target: texture)
        let cell = Int(fixture.renderer.metrics.cellWidth)
        let height = fixture.height
        #expect(Self.inkRuns(in: texture, x: cell + cell / 2, height: height).count == 1)
        #expect(Self.inkRuns(in: texture, x: 4 * cell + cell / 2, height: height).count == 2)
        // A quarter and three quarters of a period sit at opposite heights.
        let rising = Self.inkRuns(in: texture, x: 7 * cell + cell / 4, height: height)
        let falling = Self.inkRuns(in: texture, x: 7 * cell + 3 * cell / 4, height: height)
        let risingTop = try #require(rising.first?.lowerBound)
        let fallingTop = try #require(falling.first?.lowerBound)
        #expect(risingTop != fallingTop, "a curly underline must not be flat")
    }

    @Test("SGR 58 colours single, double and curly rules independently of strikeout")
    func underlineColorsDraw() throws {
        let fixture = try #require(try RenderFixture(columns: 6, rows: 1))
        fixture.renderer.themeVariant = Theme.corta.dark
        var terminal = Terminal(rows: 1, columns: 6)
        terminal.feed(Array("\u{1B}[32;4;58;2;255;0;0m  \u{1B}[4:2m  \u{1B}[4:3m  ".utf8))
        let texture = MetalRenderTarget.make(device: fixture.renderer.backend.device,
            width: fixture.width, height: fixture.height)
        fixture.renderer.renderAndWait(grid: terminal.grid,
            rect: CGRect(x: 0, y: 0, width: fixture.width, height: fixture.height),
            drawableSize: CGSize(width: fixture.width, height: fixture.height),
            cursorVisible: false, selection: nil, target: texture)
        let width = Int(fixture.renderer.metrics.cellWidth)
        for column in [0, 2, 4] {
            let pixels = (0..<fixture.height).map {
                MetalRenderTarget.pixel(of: texture, x: column * width + width / 2, y: $0)
            }
            #expect(pixels.contains { $0.r > 200 && $0.g < 10 && $0.b < 10 })
            #expect(!pixels.contains { $0.g > 60 })
        }
    }

    @Test("OSC selection text colour rebuilds selected rows and resets")
    func selectionTextColorDraws() throws {
        let fixture = try #require(try RenderFixture(columns: 6, rows: 1))
        let renderer = fixture.renderer
        renderer.themeVariant = Theme.corta.dark
        var terminal = Terminal(rows: 1, columns: 6)
        terminal.feed(Array("abc".utf8))
        let selection = TerminalSelection(start: GridPosition(row: 0, column: 0),
            end: GridPosition(row: 0, column: 1), baseScrollbackTotal: 0)
        renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: false,
            selection: selection, selectionForeground: .rgb(255, 0, 0))
        #expect(renderer.cachedGlyphs.prefix(2).allSatisfy { $0.rgba == QuadInstance.packColor(.init(1,0,0,1)) })
        #expect(renderer.cachedGlyphs.last?.rgba != QuadInstance.packColor(.init(1,0,0,1)))
        renderer.updateInstances(grid: terminal.grid, scrollOffset: 0, cursorVisible: false, selection: nil,
            selectionForeground: .rgb(255, 0, 0))
        #expect(renderer.cachedGlyphs.allSatisfy { $0.rgba != QuadInstance.packColor(.init(1,0,0,1)) })
    }

    /// The wave is built once per metrics and stays inside the cell, joining
    /// the next cell at the same height.
    @Test("the curly wave stays inside its cell")
    func waveStaysInTheCell() {
        for size in [CGFloat(10), 13, 24] {
            let font = TerminalFont.primary(ofSize: size)
            for lineSpacing in [CGFloat(1.0), 1.18, 1.4] {
                let metrics = CellMetrics(font: font, scale: 2, lineSpacing: lineSpacing).scaled(by: 2)
                let wave = TerminalRenderer.curlyWave(for: metrics, scale: 2)
                #expect(!wave.isEmpty)
                #expect(wave.allSatisfy { $0.y >= 0 && $0.y + $0.w <= Float(metrics.cellHeight) }, "\(size) \(lineSpacing)")
                let right = wave.map { $0.x + $0.z }.max() ?? 0
                #expect(abs(right - Float(metrics.cellWidth)) < 0.001)
            }
        }
    }

    /// With `ambiguous-width = wide`, `─` takes two cells and its rule spans
    /// both, rather than half of them and a gap.
    @Test("a wide box-drawing character spans both cells")
    func wideBoxDrawingSpansBothCells() throws {
        guard let fixture = try RenderFixture(columns: 4, rows: 1) else {
            Issue.record("No Metal device available in this environment")
            return
        }
        fixture.renderer.themeVariant = Theme.corta.dark
        var terminal = Terminal(rows: 1, columns: 4)
        terminal.grid.ambiguousIsWide = true
        terminal.feed(Array("\u{2500}".utf8))
        #expect(terminal.grid[0, 0].attributes.contains(.wide))
        let texture = MetalRenderTarget.make(
            device: fixture.renderer.backend.device, width: fixture.width, height: fixture.height)
        fixture.renderer.renderAndWait(
            grid: terminal.grid, rect: CGRect(x: 0, y: 0, width: fixture.width, height: fixture.height),
            drawableSize: CGSize(width: fixture.width, height: fixture.height),
            cursorVisible: false, selection: nil, target: texture)
        let cell = Int(fixture.renderer.metrics.cellWidth)
        #expect(!Self.inkRuns(in: texture, x: cell / 2, height: fixture.height).isEmpty)
        #expect(!Self.inkRuns(in: texture, x: cell + cell / 2, height: fixture.height).isEmpty)
        #expect(Self.inkRuns(in: texture, x: 2 * cell + cell / 2, height: fixture.height).isEmpty)
    }
}
