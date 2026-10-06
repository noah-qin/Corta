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

/// Renderer side of the shell-integration marks, the hovered-link
/// underline and the missing-glyph placeholder.
///
/// `.serialized`: these build a `GlyphAtlas`, which is single-threaded by
/// design — see that type's comment.
@Suite(.serialized, .metalSerialized, .enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement)) struct ShellIntegrationRenderTests {
    private struct Fixture {
        let renderer: TerminalRenderer
        let width: Int
        let height: Int
    }

    private static func fixture() throws -> Fixture? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let renderer = try TerminalRenderer(device: device, font: font, scale: 1)
        return Fixture(
            renderer: renderer, width: Int(renderer.metrics.cellWidth * 10),
            height: Int(renderer.metrics.cellHeight * 4))
    }

    private static func pixel(of texture: MTLTexture, x: Int, y: Int) -> (
        r: UInt8, g: UInt8, b: UInt8, a: UInt8
    ) {
        var bytes = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return (r: bytes[2], g: bytes[1], b: bytes[0], a: bytes[3])
    }


    /// `margin`: the left inset the grid sits in, where the status rules draw.
    private static func draw(
        _ fixture: Fixture, grid: Grid, hoveredLink: TerminalSelection? = nil, margin: Int = 0
    ) -> MTLTexture {
        let texture = MetalRenderTarget.make(
            device: fixture.renderer.backend.device, width: margin + fixture.width,
            height: fixture.height)
        fixture.renderer.renderAndWait(
            grid: grid, scrollOffset: 0,
            rect: CGRect(x: margin, y: 0, width: fixture.width, height: fixture.height),
            drawableSize: CGSize(width: margin + fixture.width, height: fixture.height),
            cursorVisible: false, selection: nil, hoveredLink: hoveredLink,
            target: texture)
        return texture
    }

    /// A prompt row gets a rule in the margin beside it, coloured by how the
    /// command ended — green for success, red for failure. Without it there
    /// is no way to see which of the last twenty commands failed.
    @Test func promptMarksPaintTheirStatusColour() throws {
        guard let fixture = try Self.fixture() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        var grid = Grid(rows: 4, columns: 10)
        grid.setMark(.promptSucceeded, atAbsoluteRow: grid.absoluteRow(ofScreenRow: 1))
        grid.setMark(.promptFailed, atAbsoluteRow: grid.absoluteRow(ofScreenRow: 2))
        let texture = Self.draw(fixture, grid: grid, margin: 8)

        let rowHeight = Int(fixture.renderer.metrics.cellHeight)
        let succeeded = Self.pixel(of: texture, x: 2, y: rowHeight + rowHeight / 2)
        let failed = Self.pixel(of: texture, x: 2, y: 2 * rowHeight + rowHeight / 2)
        let unmarked = Self.pixel(of: texture, x: 2, y: rowHeight / 2)

        #expect(succeeded.g > succeeded.r)
        #expect(failed.r > failed.g)
        #expect(unmarked.r == 0 && unmarked.g == 0 && unmarked.b == 0)
    }

    /// Turning `command-status-marks` off takes the rules away on the next
    /// frame although no row changed.
    @Test func turningTheMarksOffNeedsNoOtherChange() throws {
        guard let fixture = try Self.fixture() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        var grid = Grid(rows: 4, columns: 10)
        grid.setMark(.promptFailed, atAbsoluteRow: grid.absoluteRow(ofScreenRow: 1))
        let rowHeight = Int(fixture.renderer.metrics.cellHeight)
        let on = Self.draw(fixture, grid: grid, margin: 8)
        let ruled = Self.pixel(of: on, x: 2, y: rowHeight + rowHeight / 2)
        #expect(ruled.r > ruled.g)

        fixture.renderer.drawsCommandMarks = false
        let off = Self.draw(fixture, grid: grid, margin: 8)
        let cleared = Self.pixel(of: off, x: 2, y: rowHeight + rowHeight / 2)
        #expect(cleared.r == 0 && cleared.g == 0 && cleared.b == 0)
    }

    /// A prompt still waiting on its command, and the row output starts on,
    /// draw nothing: after `clear` the grey rule on the lone current prompt
    /// looked like a stray line (#165).
    @Test func aMarkWithoutAnOutcomeDrawsNothing() throws {
        guard let fixture = try Self.fixture() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        var grid = Grid(rows: 4, columns: 10)
        grid.setMark(.prompt, atAbsoluteRow: grid.absoluteRow(ofScreenRow: 1))
        grid.setMark(.outputStart, atAbsoluteRow: grid.absoluteRow(ofScreenRow: 2))
        let texture = Self.draw(fixture, grid: grid, margin: 8)
        let rowHeight = Int(fixture.renderer.metrics.cellHeight)
        for row in 1...2 {
            let edge = Self.pixel(of: texture, x: 2, y: row * rowHeight + rowHeight / 2)
            #expect(edge.r == 0 && edge.g == 0 && edge.b == 0)
        }
    }

    /// The mark is one rule in the margin, not a wash over the row: text
    /// has to stay readable.
    @Test func aMarkDoesNotTintTheWholeRow() throws {
        guard let fixture = try Self.fixture() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        var grid = Grid(rows: 4, columns: 10)
        grid.setMark(.promptFailed, atAbsoluteRow: grid.absoluteRow(ofScreenRow: 1))
        let texture = Self.draw(fixture, grid: grid, margin: 8)
        let rowHeight = Int(fixture.renderer.metrics.cellHeight)
        let middle = Self.pixel(
            of: texture, x: 8 + fixture.width / 2, y: rowHeight + rowHeight / 2)
        #expect(middle.r == 0 && middle.g == 0 && middle.b == 0)
    }

    /// A hovered link underlines, so the target is visible before the click
    /// that opens it.
    @Test func aHoveredLinkIsUnderlined() throws {
        guard let fixture = try Self.fixture() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let grid = Grid(rows: 4, columns: 10)
        let link = TerminalSelection(
            start: GridPosition(row: 1, column: 2), end: GridPosition(row: 1, column: 6))

        let plain = Self.draw(fixture, grid: grid)
        let rowHeight = Int(fixture.renderer.metrics.cellHeight)
        let cellWidth = Int(fixture.renderer.metrics.cellWidth)
        // The rule sits a hair above the row's bottom edge; scan the last few
        // pixel rows rather than pinning the exact one, which is a function
        // of the backing scale.
        let x = 4 * cellWidth
        let rows = ((2 * rowHeight - 4)..<(2 * rowHeight))
        func bluest(_ texture: MTLTexture, x: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            rows.map { Self.pixel(of: texture, x: x, y: $0) }.max { $0.b < $1.b }!
        }
        #expect(bluest(plain, x: x).b == 0)

        fixture.renderer.invalidate()
        let hovered = Self.draw(fixture, grid: grid, hoveredLink: link)
        let underline = bluest(hovered, x: x)
        // The rule is the theme's cyan, bluer than red in every built-in.
        #expect(underline.b > underline.r)
        #expect(underline.b > 100)
        // And only under the link, not across the whole row.
        #expect(bluest(hovered, x: 9 * cellWidth).b == 0)
    }
}
