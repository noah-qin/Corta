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

import AppKit
import CoreGraphics
import CoreText
import CortaTerminal
import Metal
import Testing

@testable import Corta

/// The font stack (`TerminalFont`) and color emoji rendering: the primary is
/// the system monospaced font, the pinned cascade resolves CJK to PingFang
/// SC and emoji to Apple Color Emoji, and color glyphs rasterise — in color —
/// into the atlas's RGBA texture and draw through the color pipeline.
/// `.serialized`: these build a `GlyphAtlas`, which is single-threaded
/// by design — see the type's comment.
@Suite(.serialized, .metalSerialized, .enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement)) struct ColorEmojiRenderTests {
    private static func makeDevice() -> MTLDevice? { MTLCreateSystemDefaultDevice() }


    /// Renders `grid` onto a fresh black texture sized exactly to the grid
    /// (same harness as `WideGlyphRenderTests`).
    private static func render(
        _ grid: Grid, renderer: TerminalRenderer, device: MTLDevice
    ) -> MTLTexture {
        let width = Int(renderer.metrics.cellWidth) * grid.columns
        let height = Int(renderer.metrics.cellHeight) * grid.rows
        let texture = MetalRenderTarget.make(
            device: device, width: width, height: height)

        renderer.renderAndWait(
            grid: grid, rect: CGRect(x: 0, y: 0, width: width, height: height),
            drawableSize: CGSize(width: width, height: height), cursorVisible: false,
            selection: nil, target: texture)
        return texture
    }

    /// Counts pixels in `texture`'s `region` that have ink (a > 0) and that
    /// are colored (r, g, b not all equal). bgra byte order.
    private static func inkAndColor(
        in texture: MTLTexture, region: MTLRegion
    ) -> (inked: Int, colored: Int) {
        let width = region.size.width, height = region.size.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: region, mipmapLevel: 0)
        var inked = 0
        var colored = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let b = bytes[i], g = bytes[i + 1], r = bytes[i + 2], a = bytes[i + 3]
            guard a > 0 else { continue }
            inked += 1
            if !(r == g && g == b) { colored += 1 }
        }
        return (inked, colored)
    }

    @Test func primaryFontIsTheSystemMonospacedFontWithAPinnedCascade() {
        let expected = NSFont.monospacedSystemFont(ofSize: 15, weight: .medium)
        let primary = TerminalFont.primary(ofSize: 15)
        #expect(CTFontCopyPostScriptName(primary) as String == expected.fontName)
        let attributes = CTFontDescriptorCopyAttributes(CTFontCopyFontDescriptor(primary))
            as? [CFString: Any]
        let cascade = attributes?[kCTFontCascadeListAttribute] as? [CTFontDescriptor]
        #expect(cascade?.count == 2)
    }

    /// The pinned cascade, asserted where it is assertable: shape 中 with the
    /// primary font and inspect the fallback run's font directly.
    @Test func cjkFallsBackToThePinnedPingFangSC() throws {
        let font = TerminalFont.primary(ofSize: 14)
        let attributed = CFAttributedStringCreate(
            nil, "中" as CFString, [kCTFontAttributeName: font] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], runs.count == 1 else {
            Issue.record("expected a single glyph run for 中")
            return
        }
        let runAttributes = CTRunGetAttributes(runs[0]) as? [CFString: Any]
        guard let fontAttribute = runAttributes?[kCTFontAttributeName] else {
            Issue.record("the 中 run carries no font attribute")
            return
        }
        // A run's font attribute is always a CTFont; the conditional above
        // is only about the key's presence.
        let runFont = fontAttribute as! CTFont
        #expect((CTFontCopyPostScriptName(runFont) as String).hasPrefix("PingFangSC"))
        #expect(!CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs))
    }

    /// An emoji scalar rasterises non-blank and *colored* into the color
    /// atlas — the grayscale coverage path drew nothing for bitmap glyphs.
    @Test func emojiRasterisesNonBlankAndInColor() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let atlas = GlyphAtlas(device: device, font: TerminalFont.primary(ofSize: 32))

        guard let info = atlas.glyph(shaping: 0x1F600, style: .regular), info.size != .zero  // 😀
        else {
            Issue.record("😀 failed to shape in this environment")
            return
        }
        #expect(info.isColor, "the emoji run must be detected as a color font")
        #expect(atlas.fallbackHits > 0, "the emoji run must come from the cascade list")

        let originX = Int(info.uvRect.x * Float(atlas.atlasPixelSize))
        let originY = Int(info.uvRect.y * Float(atlas.atlasPixelSize))
        let region = MTLRegionMake2D(originX, originY, Int(info.size.x), Int(info.size.y))
        let result = Self.inkAndColor(in: atlas.colorTexture, region: region)
        #expect(result.inked > 0, "expected ink in the emoji's atlas rect")
        #expect(result.colored > 0, "expected at least one non-grey pixel — emoji render in color")
    }

    /// A CJK scalar keeps rasterising through the grayscale path, with the
    /// fallback attributed to the cascade (PingFang SC, per the factory-level
    /// assertion above).
    @Test func cjkStillRasterisesThroughTheGrayscalePath() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let atlas = GlyphAtlas(device: device, font: TerminalFont.primary(ofSize: 32))

        let info = atlas.glyph(shaping: 0x4E2D, style: .regular)  // 中
        #expect(info != nil)
        #expect(info?.size != .zero)
        #expect(info?.isColor == false)
        #expect(atlas.fallbackHits > 0)
    }

    /// End to end: 😀 through the grid and the renderer inks its two-cell
    /// box in color — exercising the third draw call and the wide-glyph
    /// scale-and-centre path for color quads.
    @Test func emojiRendersInColorThroughTheRenderer() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let renderer = try TerminalRenderer(
            device: device, font: TerminalFont.primary(ofSize: 14), scale: 1)

        var terminal = Terminal(rows: 2, columns: 6)
        terminal.feed(Array("😀".utf8))
        let grid = terminal.grid
        #expect(grid[0, 0].attributes.contains(.wide))

        let texture = Self.render(grid, renderer: renderer, device: device)
        let cellWidth = Int(renderer.metrics.cellWidth)
        let cellHeight = Int(renderer.metrics.cellHeight)
        let box = MTLRegionMake2D(0, 0, cellWidth * 2, cellHeight)
        let result = Self.inkAndColor(in: texture, region: box)
        #expect(result.inked > 0, "expected the emoji to ink its two-cell box")
        #expect(result.colored > 0, "expected colored pixels in the rendered emoji")
    }

    /// The atlas draws an emoji at the size two cells take, so the renderer
    /// maps it texel for texel: a bitmap scaled on the GPU, or placed at a
    /// fractional pixel, is resampled and comes out soft.
    @Test(arguments: [1.0, 2.0])
    func emojiBitmapFitsTwoCellsWithoutScaling(scale: Double) throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let renderer = try TerminalRenderer(
            device: device, font: TerminalFont.primary(ofSize: 14), scale: scale)
        let info = try #require(renderer.glyphAtlas.glyph(shaping: 0x1F600, style: .regular))
        #expect(info.isColor)
        let boxWidth = Float(renderer.metrics.cellWidth) * 2
        #expect(info.size.x <= boxWidth, "the bitmap is wider than its two cells")
        let placed = TerminalRenderer.colorGlyphPlacement(
            info, cellOrigin: .zero, boxWidth: boxWidth,
            cellHeight: Float(renderer.metrics.cellHeight))
        #expect(placed.size == info.size, "a two-cell emoji was scaled")
        #expect(placed.origin.x == placed.origin.x.rounded())
        #expect(placed.origin.y == placed.origin.y.rounded())
    }

    /// A small design stays smaller than its large counterpart once drawn:
    /// the atlas scales a bitmap emoji by its whole design square, which is
    /// the same for both, never by the part of it that is drawn.
    @Test func smallEmojiDesignsStaySmall() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let renderer = try TerminalRenderer(
            device: device, font: TerminalFont.primary(ofSize: 14), scale: 2)
        let box = MTLRegionMake2D(
            0, 0, Int(renderer.metrics.cellWidth) * 2, Int(renderer.metrics.cellHeight))
        func drawn(_ text: String) -> Int {
            var terminal = Terminal(rows: 1, columns: 4)
            terminal.feed(Array(text.utf8))
            return Self.inkAndColor(
                in: Self.render(terminal.grid, renderer: renderer, device: device), region: box
            ).colored
        }
        let small = drawn("\u{1F538}"), large = drawn("\u{1F536}")
        #expect(small > 0 && large > 0)
        #expect(Double(small) < Double(large) * 0.8, "🔸 drew as large as 🔶: \(small) vs \(large)")
    }

    /// A text-default base with VS16 (✍️) is one column in the grid, as
    /// wcwidth counts it, but draws into a blank cell after it. Without VS16,
    /// or with text after it, it keeps to its own cell.
    @Test func emojiSelectorOverflowsOnlyIntoABlankCell() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let renderer = try TerminalRenderer(
            device: device, font: TerminalFont.primary(ofSize: 14), scale: 2)
        let cellWidth = Int(renderer.metrics.cellWidth)
        let cellHeight = Int(renderer.metrics.cellHeight)
        func coloredInSecondCell(_ text: String) -> Int {
            var terminal = Terminal(rows: 1, columns: 6)
            terminal.feed(Array(text.utf8))
            let texture = Self.render(terminal.grid, renderer: renderer, device: device)
            return Self.inkAndColor(
                in: texture, region: MTLRegionMake2D(cellWidth, 0, cellWidth, cellHeight)
            ).colored
        }
        var terminal = Terminal(rows: 1, columns: 6)
        terminal.feed(Array("\u{270D}\u{FE0F} x".utf8))
        #expect(!terminal.grid[0, 0].attributes.contains(.wide), "VS16 widened the cell")

        #expect(coloredInSecondCell("\u{270D}\u{FE0F} x") > 0, "✍️ did not draw into the blank cell")
        // The foreground is not a pure grey, so text counts as colored too:
        // the same x after a plain letter is the baseline.
        let squeezed = coloredInSecondCell("\u{270D}\u{FE0F}x"), plain = coloredInSecondCell("ax")
        #expect(squeezed == plain, "✍️ drew over the text after it: \(squeezed) vs \(plain)")
        // 🖼 without VS16: one column, drawn from the color font all the same.
        #expect(renderer.glyphAtlas.glyph(shaping: 0x1F5BC, style: .regular)?.isColor == true)
        #expect(coloredInSecondCell("\u{1F5BC} x") == 0, "an emoji without VS16 overflowed")
    }

    /// Same end to end for a ZWJ cluster (👨‍👩‍👧‍👦): the core collapses the
    /// sequence into one wide cluster cell (`Grid.write`'s ZWJ path), and
    /// the cluster must rasterise in color exactly like a single scalar.
    /// Runs at scale 2 as well — the live app rasterises its atlas at
    /// `font size * backingScale`.
    @Test(arguments: [1.0, 2.0])
    func zwjClusterRendersInColorThroughTheRenderer(scale: Double) throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let renderer = try TerminalRenderer(
            device: device, font: TerminalFont.primary(ofSize: 14), scale: scale)

        var terminal = Terminal(rows: 2, columns: 6)
        terminal.feed(Array("👨‍👩‍👧‍👦".utf8))
        let grid = terminal.grid
        #expect(grid[0, 0].attributes.contains(.wide))
        #expect(!grid[0, 0].grapheme.isNone)

        let texture = Self.render(grid, renderer: renderer, device: device)
        let cellWidth = Int(renderer.metrics.cellWidth)
        let cellHeight = Int(renderer.metrics.cellHeight)
        let box = MTLRegionMake2D(0, 0, cellWidth * 2, cellHeight)
        let result = Self.inkAndColor(in: texture, region: box)
        #expect(result.inked > 0, "expected the family emoji to ink its two-cell box")
        #expect(result.colored > 0, "expected the family emoji to render in color, not gray")
    }
}
