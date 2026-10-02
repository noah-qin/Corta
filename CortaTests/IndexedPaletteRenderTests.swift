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
import Metal
import Testing

@testable import Corta

/// Render-path integration: an OSC 4 override changes what is
/// painted, not only what a query answers (`docs/DESIGN.md` §7). Same
/// offscreen-texture pattern `CursorStyleRenderTests` already uses.
/// `.serialized`: these build a `GlyphAtlas`, which is single-threaded by
/// design — see the type's comment.
@Suite(.serialized, .metalSerialized, .enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement)) struct IndexedPaletteRenderTests {
    private static func pixel(of texture: MTLTexture, x: Int, y: Int) -> (
        r: UInt8, g: UInt8, b: UInt8, a: UInt8
    ) {
        var bytes = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return (r: bytes[2], g: bytes[1], b: bytes[0], a: bytes[3])
    }


    /// Renders a 4x10 grid whose whole first row carries background index
    /// 196 (xterm's cube red, `48;5;196m`), with `oscBeforeContent` fed
    /// first if given — an OSC 4 override, or nothing.
    private static func renderWithBackgroundIndex196(
        oscBeforeContent: String?
    ) throws -> (
        texture: MTLTexture, renderer: TerminalRenderer, terminal: Terminal
    ) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let renderer = try TerminalRenderer(device: device, font: font, scale: 1)

        var terminal = Terminal(rows: 4, columns: 10)
        if let oscBeforeContent {
            terminal.feed(Array(oscBeforeContent.utf8))
        }
        terminal.feed(Array("\u{1B}[48;5;196m    \u{1B}[0m".utf8))
        let grid = terminal.grid

        let width = Int(renderer.metrics.cellWidth * 10)
        let height = Int(renderer.metrics.cellHeight * 4)
        let texture = MetalRenderTarget.make(device: device, width: width, height: height)

        renderer.renderAndWait(
            grid: grid, rect: CGRect(x: 0, y: 0, width: width, height: height),
            drawableSize: CGSize(width: width, height: height), cursorVisible: false,
            selection: nil,
            indexedOverrides: terminal.indexedPalette.overrides,
            indexedOverridesGeneration: terminal.indexedPalette.overridesGeneration,
            target: texture)
        return (texture, renderer, terminal)
    }

    @Test func untouchedIndexPaintsXtermsCubeColour() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let (texture, renderer, _) = try Self.renderWithBackgroundIndex196(
            oscBeforeContent: nil)
        let cellW = Int(renderer.metrics.cellWidth)
        let cellH = Int(renderer.metrics.cellHeight)
        let sample = Self.pixel(of: texture, x: cellW / 2, y: cellH / 2)
        // Index 196 is xterm's cube red: (255, 0, 0).
        #expect(sample.r > 200, "expected cube red, got \(sample)")
        #expect(sample.g < 30, "expected cube red, got \(sample)")
        #expect(sample.b < 30, "expected cube red, got \(sample)")
    }

    @Test func oscOverriddenIndexPaintsTheOverrideNotTheDefault() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            Issue.record("No Metal device available in this environment")
            return
        }
        // Override index 196 to pure green before the cell that uses it.
        let (texture, renderer, terminal) = try Self.renderWithBackgroundIndex196(
            oscBeforeContent: "\u{1B}]4;196;#00ff00\u{1B}\\")
        let cellW = Int(renderer.metrics.cellWidth)
        let cellH = Int(renderer.metrics.cellHeight)
        let sample = Self.pixel(of: texture, x: cellW / 2, y: cellH / 2)
        #expect(sample.r < 30, "expected the override (green), got \(sample)")
        #expect(sample.g > 200, "expected the override (green), got \(sample)")
        #expect(sample.b < 30, "expected the override (green), got \(sample)")
        // The query and the paint agree — the whole point of this pass.
        #expect(terminal.indexedPalette.color(at: 196) as (UInt8, UInt8, UInt8) == (0, 255, 0))
    }

    @Test func resettingAnOverrideRepaintsTheDefault() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let (texture, renderer, _) = try Self.renderWithBackgroundIndex196(
            oscBeforeContent: "\u{1B}]4;196;#00ff00\u{1B}\\\u{1B}]104;196\u{1B}\\")
        let cellW = Int(renderer.metrics.cellWidth)
        let cellH = Int(renderer.metrics.cellHeight)
        let sample = Self.pixel(of: texture, x: cellW / 2, y: cellH / 2)
        // Back to xterm's cube red.
        #expect(sample.r > 200, "expected cube red after reset, got \(sample)")
        #expect(sample.g < 30, "expected cube red after reset, got \(sample)")
    }

    /// The invalidation this pass added (`cachedIndexedOverridesGeneration`):
    /// a cell whose *content* never changes still has to repaint once an
    /// override lands, because nothing about `Cell`'s own stored bitfield
    /// changed — only what index 196 resolves to did.
    @Test func aLateOverrideRepaintsAnAlreadyCachedCellWithNoContentChange() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let renderer = try TerminalRenderer(device: device, font: font, scale: 1)
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.feed(Array("\u{1B}[48;5;196m    \u{1B}[0m".utf8))

        let width = Int(renderer.metrics.cellWidth * 10)
        let height = Int(renderer.metrics.cellHeight * 4)
        let texture = MetalRenderTarget.make(device: device, width: width, height: height)

        func renderOnce() {
            renderer.renderAndWait(
                grid: terminal.grid, rect: CGRect(x: 0, y: 0, width: width, height: height),
                drawableSize: CGSize(width: width, height: height), cursorVisible: false,
                selection: nil,
                indexedOverrides: terminal.indexedPalette.overrides,
                indexedOverridesGeneration: terminal.indexedPalette.overridesGeneration,
                target: texture)
        }

        renderOnce()
        let cellW = Int(renderer.metrics.cellWidth)
        let cellH = Int(renderer.metrics.cellHeight)
        let before = Self.pixel(of: texture, x: cellW / 2, y: cellH / 2)
        #expect(before.r > 200 && before.g < 30, "expected cube red before the override, got \(before)")

        // The override lands without touching the grid's own content at all.
        terminal.feed(Array("\u{1B}]4;196;#00ff00\u{1B}\\".utf8))
        renderOnce()
        let after = Self.pixel(of: texture, x: cellW / 2, y: cellH / 2)
        #expect(after.g > 200 && after.r < 30, "expected the override to repaint the cell, got \(after)")
    }
}
