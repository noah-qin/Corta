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

    /// These are the exact kinds of borders in the Claude Code reproducer.
    /// A font glyph can have the right advance yet leave a gap at every cell.
    @Test func tableBordersMeetAtEveryCellBoundary() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        for size: CGFloat in [12, 17] {
            for scale: CGFloat in [1, 2] {
                let renderer = try TerminalRenderer(device: device,
                    font: TerminalFont.primary(ofSize: size), scale: scale)
                var terminal = Terminal(rows: 3, columns: 5)
                terminal.feed(Array("\u{1B}[37m┌───┐\r\n│   │\r\n└───┘".utf8))
                let w = Int(renderer.metrics.cellWidth), h = Int(renderer.metrics.cellHeight)
                let texture = MetalRenderTarget.make(device: device, width: 5 * w, height: 3 * h)
                renderer.renderAndWait(grid: terminal.grid,
                    rect: CGRect(x: 0, y: 0, width: 5*w, height: 3*h),
                    drawableSize: CGSize(width: 5*w, height: 3*h), cursorVisible: false,
                    selection: nil, target: texture)
                var bytes = [UInt8](repeating: 0, count: 5*w*3*h*4)
                texture.getBytes(&bytes, bytesPerRow: 5*w*4,
                    from: MTLRegionMake2D(0, 0, 5*w, 3*h), mipmapLevel: 0)
                let stroke = max(1, Int(scale))
                let midX = (w-stroke)/2, midY = (h-stroke)/2
                func ink(_ x: Int, _ y: Int) -> Bool {
                    let i = (y*5*w+x)*4
                    return Int(bytes[i])+Int(bytes[i+1])+Int(bytes[i+2]) > 100
                }
                for x in midX..<(4*w+midX) {
                    #expect(ink(x, midY), "top border gap at \(x), size \(size), scale \(scale)")
                    #expect(ink(x, 2*h+midY), "bottom border gap at \(x)")
                }
                for y in midY..<(2*h+midY) {
                    #expect(ink(midX, y), "left border gap at \(y)")
                    #expect(ink(4*w+midX, y), "right border gap at \(y)")
                }
            }
        }
    }

    @Test func faintTableStrokeHasUniformColorAcrossItsJunction() throws {
        let (_, _, _, optionalTexture) = try Self.render("\u{1B}[2m─")
        let texture = try #require(optionalTexture)
        let width = texture.width, height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let y = (height - 1) / 2
        for channel in 0..<3 {
            #expect(pixels[(y * width) * 4 + channel] == pixels[(y * width + width / 2) * 4 + channel])
        }
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
