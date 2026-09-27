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

/// `.serialized`: builds a `GlyphAtlas`, which is single-threaded by design.
@Suite(
    "Block elements", .serialized, .metalSerialized,
    .enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
struct BlockElementRenderTests {
    /// The defect: a cell is `advance.rounded(.up)` wide, so a font whose
    /// advance is 8.4pt gets a 9pt cell and every glyph leaves a point bare on
    /// its right. Between letters that is invisible; between block characters
    /// it is a grid of gaps, and the cell's average colour falls well below
    /// the requested one — measured, U+2588 inked 88% of its cell and an
    /// orange (255,140,0) averaged out to (203,111,0), which reads as pink.
    @Test func fullBlockInksItsWholeCellAtTheRequestedColour() throws {
        let (inked, total, mean, texture) = try Self.render("\u{2588}")
        if inked != total || mean != SIMD3<Int>(255, 140, 0), let texture {
            MetalRenderTarget.attachPNG(texture, named: "full-block-render.png")
        }
        #expect(inked == total)
        #expect(mean == SIMD3<Int>(255, 140, 0))
    }

    /// Halves have to tile: whatever rounding costs the top, the bottom gets.
    @Test func theTwoHalvesTileExactly() throws {
        let (upper, total, _, upperTexture) = try Self.render("\u{2580}")
        let (lower, _, _, lowerTexture) = try Self.render("\u{2584}")
        if upper + lower != total {
            if let upperTexture {
                MetalRenderTarget.attachPNG(upperTexture, named: "upper-half-block-render.png")
            }
            if let lowerTexture {
                MetalRenderTarget.attachPNG(lowerTexture, named: "lower-half-block-render.png")
            }
        }
        #expect(upper + lower == total)
    }

    /// Left and right halves likewise.
    @Test func theLeftAndRightHalvesTileExactly() throws {
        let (left, total, _, leftTexture) = try Self.render("\u{258C}")
        let (right, _, _, rightTexture) = try Self.render("\u{2590}")
        if left + right != total {
            if let leftTexture {
                MetalRenderTarget.attachPNG(leftTexture, named: "left-half-block-render.png")
            }
            if let rightTexture {
                MetalRenderTarget.attachPNG(rightTexture, named: "right-half-block-render.png")
            }
        }
        #expect(left + right == total)
    }

    /// Renders one cell holding `character` in (255,140,0) and reports how
    /// many pixels have ink, the cell's pixel count, its average colour, and
    /// the texture itself, so a failing test can attach it.
    private static func render(
        _ character: String
    ) throws -> (inked: Int, total: Int, mean: SIMD3<Int>, texture: MTLTexture?) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        let renderer = try TerminalRenderer(device: device, font: font, scale: 1)

        var terminal = Terminal(rows: 1, columns: 1)
        terminal.feed(Array("\u{1B}[38;2;255;140;0m\(character)".utf8))
        let grid = terminal.grid
        let w = Int(renderer.metrics.cellWidth), h = Int(renderer.metrics.cellHeight)

        let texture = MetalRenderTarget.make(
            device: device, width: w, height: h)
        renderer.renderAndWait(
            grid: grid, rect: CGRect(x: 0, y: 0, width: w, height: h),
            drawableSize: CGSize(width: w, height: h), cursorVisible: false,
            selection: nil, target: texture)

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(
            &pixels, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        var inked = 0
        var sum = SIMD3<Int>(0, 0, 0)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let blue = Int(pixels[i]), green = Int(pixels[i + 1]), red = Int(pixels[i + 2])
            sum &+= SIMD3<Int>(red, green, blue)
            if red + green + blue > 30 { inked += 1 }
        }
        let count = w * h
        return (inked, count, sum / SIMD3<Int>(repeating: count), texture)
    }
}
