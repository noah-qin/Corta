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

/// Every theme colour reaches the glass (#125). `DocumentationDriftTests`
/// proves a documented key is parsed; this proves the parsed colour is
/// painted — `cursor` was once parsed for a release and drawn as a fixed
/// grey. Each test starts from config text, so a key that stops parsing
/// fails here too, and samples pixels the way `IndexedPaletteRenderTests`
/// does. Full blocks (`█`) are quads, not antialiased glyphs, so a sampled
/// pixel is the colour itself.
///
/// `.serialized`: these build a `GlyphAtlas`, which is single-threaded by
/// design — see the type's comment.
@Suite(.serialized, .metalSerialized, .enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement)) struct ThemeColorRenderTests {
    private typealias Pixel = (r: UInt8, g: UInt8, b: UInt8, a: UInt8)

    private static func pixel(of texture: MTLTexture, x: Int, y: Int) -> Pixel {
        var bytes = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return (r: bytes[2], g: bytes[1], b: bytes[0], a: bytes[3])
    }

    private static func byte(_ value: Float) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }

    /// Within `tolerance` per channel of `color` drawn at its alpha over
    /// `background` — the straight source-over the pipelines blend with.
    private static func matches(
        _ pixel: Pixel, _ color: SIMD4<Float>, over background: SIMD4<Float>, tolerance: Int = 3
    ) -> Bool {
        let a = color.w
        let expected = [
            byte(color.x * a + background.x * (1 - a)), byte(color.y * a + background.y * (1 - a)),
            byte(color.z * a + background.z * (1 - a)),
        ]
        return abs(Int(pixel.r) - expected[0]) <= tolerance
            && abs(Int(pixel.g) - expected[1]) <= tolerance
            && abs(Int(pixel.b) - expected[2]) <= tolerance
    }

    private struct Frame {
        let texture: MTLTexture
        let cellWidth: Int
        let cellHeight: Int

        func center(row: Int, column: Int) -> Pixel {
            ThemeColorRenderTests.pixel(
                of: texture, x: column * cellWidth + cellWidth / 2, y: row * cellHeight + cellHeight / 2)
        }
    }

    /// Renders `grid` with `variant` pinned, cleared to the variant's
    /// background as `PaneFrameLoop` clears to the live one.
    private static func render(
        _ grid: Grid, variant: Theme.Variant, cursorVisible: Bool = false,
        selection: TerminalSelection? = nil, searchMatches: [TerminalSelection] = [],
        currentSearchMatchIndex: Int? = nil, hoveredLink: TerminalSelection? = nil
    ) throws -> Frame {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let renderer = try TerminalRenderer(device: device, font: font, scale: 1)
        renderer.themeVariant = variant
        let cellWidth = Int(renderer.metrics.cellWidth)
        let cellHeight = Int(renderer.metrics.cellHeight)
        let width = cellWidth * grid.columns
        let height = cellHeight * grid.rows
        let texture = MetalRenderTarget.make(device: device, width: width, height: height)
        let background = variant.background
        renderer.renderAndWait(
            grid: grid, rect: CGRect(x: 0, y: 0, width: width, height: height),
            drawableSize: CGSize(width: width, height: height), cursorVisible: cursorVisible,
            selection: selection, searchMatches: searchMatches,
            currentSearchMatchIndex: currentSearchMatchIndex, hoveredLink: hoveredLink,
            target: texture,
            clearColor: MTLClearColorMake(
                Double(background.x), Double(background.y), Double(background.z), 1))
        return Frame(texture: texture, cellWidth: cellWidth, cellHeight: cellHeight)
    }

    /// A colour no built-in has, distinct per slot: `#rrggbb` and its value.
    private static func probeColor(_ seed: Int) -> (hex: String, value: SIMD4<Float>) {
        let r = (20 + seed * 13) % 256
        let g = (230 + seed * 245) % 256  // down by 11 a step, wrapping
        let b = (60 + seed * 29) % 256
        let hex = String(format: "#%02x%02x%02x", r, g, b)
        return (hex, SIMD4<Float>(Float(r) / 255, Float(g) / 255, Float(b) / 255, 1))
    }

    private static func parsedTheme(_ text: String, named name: String) throws -> Theme {
        let configuration = Configuration.parse(text).configuration
        return try #require(configuration.customThemes.first { $0.name == name })
    }

    /// Row 0: a full block in the default foreground, then one in reverse
    /// video (drawn in the default background). Row 1: the sixteen ANSI
    /// slots. The cursor ends on row 2, column 0, an empty cell.
    private static func probeGrid() -> Grid {
        var terminal = Terminal(rows: 3, columns: 16)
        var text = "█\u{1B}[7m█\u{1B}[0m\r\n"
        for slot in 0..<16 {
            text += "\u{1B}[\(slot < 8 ? 30 + slot : 90 + slot - 8)m█"
        }
        text += "\u{1B}[0m\r\n"
        terminal.feed(Array(text.utf8))
        return terminal.grid
    }

    /// The three colours a variant owns and all sixteen slots, set one key
    /// at a time (`<variant>.ansi<N>`) for dark and as one list
    /// (`<variant>.ansi`) for light: every colour key in
    /// `docs/CONFIGURATION.md` §4. `name` is a label, never painted;
    /// `inherit` has its own test below.
    @Test(arguments: ["dark", "light"])
    func everyThemeColourKeyIsPainted(variantName: String) throws {
        let foreground = Self.probeColor(1)
        let background = Self.probeColor(2)
        let cursor = Self.probeColor(3)
        let slots = (0..<16).map { Self.probeColor(10 + $0) }
        var text = """
            theme = probe
            theme.probe.\(variantName).foreground = \(foreground.hex)
            theme.probe.\(variantName).background = \(background.hex)
            theme.probe.\(variantName).cursor = \(cursor.hex)

            """
        if variantName == "dark" {
            for (index, slot) in slots.enumerated() {
                text += "theme.probe.dark.ansi\(index) = \(slot.hex)\n"
            }
        } else {
            text += "theme.probe.light.ansi = \(slots.map(\.hex).joined(separator: ", "))\n"
        }
        let theme = try Self.parsedTheme(text, named: "probe")
        let variant = variantName == "dark" ? theme.dark : theme.light

        let frame = try Self.render(Self.probeGrid(), variant: variant, cursorVisible: true)
        let opaque = SIMD4<Float>(0, 0, 0, 1)
        #expect(
            Self.matches(frame.center(row: 0, column: 0), foreground.value, over: opaque),
            "foreground: \(frame.center(row: 0, column: 0))")
        #expect(
            Self.matches(frame.center(row: 0, column: 1), background.value, over: opaque),
            "background: \(frame.center(row: 0, column: 1))")
        #expect(
            Self.matches(frame.center(row: 2, column: 0), cursor.value, over: opaque),
            "cursor: \(frame.center(row: 2, column: 0))")
        for (index, slot) in slots.enumerated() {
            let sample = frame.center(row: 1, column: index)
            #expect(Self.matches(sample, slot.value, over: opaque), "ansi\(index): \(sample)")
        }
    }

    /// `inherit`: what a theme leaves unset is the base theme's, painted.
    @Test func anInheritedColourIsPainted() throws {
        let theme = try Self.parsedTheme(
            """
            theme.probe.inherit = solarized
            theme.probe.dark.foreground = #ffffff
            """, named: "probe")
        let frame = try Self.render(Self.probeGrid(), variant: theme.dark)
        let opaque = SIMD4<Float>(0, 0, 0, 1)
        let red = frame.center(row: 1, column: 1)
        #expect(Self.matches(red, Theme.solarized.dark.ansi[1], over: opaque), "solarized red: \(red)")
        #expect(Self.matches(frame.center(row: 0, column: 0), SIMD4<Float>(1, 1, 1, 1), over: opaque))
    }

    // MARK: - Derived colours

    private static func probeVariant() throws -> Theme.Variant {
        var text = "theme.probe.dark.foreground = \(probeColor(1).hex)\n"
        text += "theme.probe.dark.background = \(probeColor(2).hex)\n"
        for index in 0..<16 { text += "theme.probe.dark.ansi\(index) = \(probeColor(10 + index).hex)\n" }
        return try parsedTheme(text, named: "probe").dark
    }

    /// Selection, search matches and the hovered-link rule follow the
    /// theme's slots (`Theme.Variant.overlayColors`), not constants.
    @Test func overlayFillsAreDerivedFromTheTheme() throws {
        let variant = try Self.probeVariant()
        let overlay = variant.overlayColors
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.feed(Array("\u{1B}[4;1H".utf8))  // the cursor out of the way
        let grid = terminal.grid
        let row0 = TerminalSelection(start: GridPosition(row: 0, column: 0), end: GridPosition(row: 0, column: 3))
        let row1 = TerminalSelection(start: GridPosition(row: 1, column: 0), end: GridPosition(row: 1, column: 3))
        let row2 = TerminalSelection(start: GridPosition(row: 2, column: 0), end: GridPosition(row: 2, column: 3))

        let frame = try Self.render(
            grid, variant: variant, selection: row0, searchMatches: [row1, row2],
            currentSearchMatchIndex: 1, hoveredLink: row0)
        let background = variant.background
        let selection = frame.center(row: 0, column: 1)
        #expect(Self.matches(selection, overlay.selection, over: background), "selection: \(selection)")
        let match = frame.center(row: 1, column: 1)
        #expect(Self.matches(match, overlay.searchMatch, over: background), "match: \(match)")
        let current = frame.center(row: 2, column: 1)
        #expect(Self.matches(current, overlay.currentSearchMatch, over: background), "current: \(current)")

        // The rule sits two device pixels above the row's bottom, over the
        // selection; opaque, so it is the link colour alone.
        let rule = Self.pixel(of: frame.texture, x: frame.cellWidth + frame.cellWidth / 2, y: frame.cellHeight - 2)
        #expect(Self.matches(rule, overlay.linkUnderline, over: background), "link: \(rule)")
    }

    /// The prompt marks: the theme's green and red for an outcome, and the
    /// midpoint of foreground and background for an interrupted command.
    @Test func promptMarksAreDerivedFromTheTheme() throws {
        let variant = try Self.probeVariant()
        let overlay = variant.overlayColors
        var grid = Grid(rows: 4, columns: 10)
        grid.setMark(.promptSucceeded, atAbsoluteRow: grid.absoluteRow(ofScreenRow: 0))
        grid.setMark(.promptFailed, atAbsoluteRow: grid.absoluteRow(ofScreenRow: 1))
        grid.setMark(.promptInterrupted, atAbsoluteRow: grid.absoluteRow(ofScreenRow: 2))
        let frame = try Self.render(grid, variant: variant)
        let background = variant.background
        for (row, color, name) in [
            (0, overlay.markSucceeded, "succeeded"), (1, overlay.markFailed, "failed"),
            (2, overlay.markInterrupted, "interrupted"),
        ] {
            let edge = Self.pixel(of: frame.texture, x: 0, y: row * frame.cellHeight + frame.cellHeight / 2)
            #expect(Self.matches(edge, color, over: background), "\(name): \(edge)")
        }
    }

    // MARK: - The block cursor

    /// Opaque, in the cursor colour, with the character under it in the
    /// theme background — the way Terminal.app draws it — rather than a
    /// translucent tint over a character in its own colour.
    @Test func aBlockCursorInvertsTheCharacterUnderIt() throws {
        var variant = Theme.corta.dark
        variant.cursor = SIMD4<Float>(0, 0.8, 0, 1)
        var terminal = Terminal(rows: 2, columns: 10)
        terminal.feed(Array("█M\u{1B}[1;1H".utf8))  // the cursor back onto the block
        let opaque = SIMD4<Float>(0, 0, 0, 1)

        let onBlock = try Self.render(terminal.grid, variant: variant, cursorVisible: true)
        let inverted = onBlock.center(row: 0, column: 0)
        #expect(Self.matches(inverted, variant.background, over: opaque), "the block, inverted: \(inverted)")

        terminal.feed(Array("\u{1B}[1;2H".utf8))  // onto the letter
        let onLetter = try Self.render(terminal.grid, variant: variant, cursorVisible: true)
        var cursorPixels = 0
        var backgroundPixels = 0
        var foregroundPixels = 0
        for y in 0..<onLetter.cellHeight {
            for x in onLetter.cellWidth..<(2 * onLetter.cellWidth) {
                let sample = Self.pixel(of: onLetter.texture, x: x, y: y)
                if Self.matches(sample, variant.cursor, over: opaque, tolerance: 8) { cursorPixels += 1 }
                if Self.matches(sample, variant.background, over: opaque, tolerance: 8) { backgroundPixels += 1 }
                if Self.matches(sample, variant.foreground, over: opaque, tolerance: 40) { foregroundPixels += 1 }
            }
        }
        #expect(cursorPixels > 0, "the cell is the cursor colour")
        #expect(backgroundPixels > 0, "the letter's ink is the background colour")
        #expect(foregroundPixels == 0, "nothing keeps the letter's own colour")
    }

    /// A wide character inverts whole: both of its cells carry the cursor.
    @Test func aBlockCursorCoversAWideCharacter() throws {
        var variant = Theme.corta.dark
        variant.cursor = SIMD4<Float>(0, 0.8, 0, 1)
        var terminal = Terminal(rows: 2, columns: 10)
        terminal.feed(Array("中\u{1B}[1;1H".utf8))
        let frame = try Self.render(terminal.grid, variant: variant, cursorVisible: true)
        let opaque = SIMD4<Float>(0, 0, 0, 1)
        // Corners: outside the ideograph's ink in both cells.
        for x in [1, 2 * frame.cellWidth - 2] {
            let corner = Self.pixel(of: frame.texture, x: x, y: frame.cellHeight - 1)
            #expect(Self.matches(corner, variant.cursor, over: opaque), "x \(x): \(corner)")
        }
    }

    // MARK: - Contrast

    /// WCAG 2 relative luminance of an sRGB colour.
    private static func luminance(_ color: SIMD4<Float>) -> Float {
        func linear(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(color.x) + 0.7152 * linear(color.y) + 0.0722 * linear(color.z)
    }

    private static func contrast(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func composite(_ color: SIMD4<Float>, over background: SIMD4<Float>) -> SIMD4<Float> {
        var result = color * color.w + background * (1 - color.w)
        result.w = 1
        return result
    }

    /// The acceptance for #125: a selection shows on its background, light
    /// or dark, and the text over it stays readable. The old fixed blue was
    /// chosen for a dark surface; Corta's own dark blue, taken plainly,
    /// reached only 1.2:1. Figures for the built-ins are in the pull request.
    @Test(arguments: Theme.builtIn.flatMap { [($0.name + ".dark", $0.dark), ($0.name + ".light", $0.light)] })
    func aSelectionIsVisibleAndItsTextReadable(name: String, variant: Theme.Variant) {
        let selected = Self.composite(variant.overlayColors.selection, over: variant.background)
        let visible = Self.contrast(selected, variant.background)
        let readable = Self.contrast(variant.foreground, selected)
        #expect(visible >= 1.5, "\(name): selection on background \(visible):1")
        #expect(readable >= 2.4, "\(name): text on selection \(readable):1")
    }
}
