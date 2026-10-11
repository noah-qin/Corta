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
        for size: CGFloat in [12, 14, 17, 40] {
            for scale: CGFloat in [1, 1.25, 1.5, 2, 3] {
                let renderer = try TerminalRenderer(device: device,
                    font: TerminalFont.primary(ofSize: size), scale: scale)
                for (weight, border) in [(1, "┌───┐\r\n│   │\r\n└───┘"),
                                         (2, "┏━━━┓\r\n┃   ┃\r\n┗━━━┛")] {
                    var terminal = Terminal(rows: 3, columns: 5)
                    terminal.feed(Array("\u{1B}[37m\(border)".utf8))
                    let w = Int(renderer.metrics.cellWidth), h = Int(renderer.metrics.cellHeight)
                    let texture = MetalRenderTarget.make(device: device, width: 5 * w, height: 3 * h)
                    renderer.renderAndWait(grid: terminal.grid,
                        rect: CGRect(x: 0, y: 0, width: 5*w, height: 3*h),
                        drawableSize: CGSize(width: 5*w, height: 3*h), cursorVisible: false,
                        selection: nil, target: texture)
                    var bytes = [UInt8](repeating: 0, count: 5*w*3*h*4)
                    texture.getBytes(&bytes, bytesPerRow: 5*w*4,
                        from: MTLRegionMake2D(0, 0, 5*w, 3*h), mipmapLevel: 0)
                    let stroke = max(1, Int(scale)) * weight
                    let midX = (w-stroke)/2, midY = (h-stroke)/2
                    func ink(_ x: Int, _ y: Int) -> Bool {
                        let i = (y*5*w+x)*4
                        return Int(bytes[i])+Int(bytes[i+1])+Int(bytes[i+2]) > 100
                    }
                    if size == 17 && scale == 2 {
                        MetalRenderTarget.attachPNG(texture, named: "square-table-corners-17-2-weight-\(weight).png")
                    }
                    for x in midX..<(4*w+midX) {
                        #expect(ink(x, midY), "top border gap at \(x), size \(size), scale \(scale)")
                        #expect(ink(x, 2*h+midY), "bottom border gap at \(x)")
                    }
                    for y in midY..<(2*h+midY) {
                        #expect(ink(midX, y), "left border gap at \(y)")
                        #expect(ink(4*w+midX, y), "right border gap at \(y)")
                    }
                    // The connected border must also stop at its four square
                    // outside edges: overlap at a join must not make a spur.
                    for y in 0..<(3*h) {
                        for x in 0..<(5*w) {
                            let horizontal = x >= midX && x < 4*w+midX+stroke &&
                                ((y >= midY && y < midY+stroke) ||
                                 (y >= 2*h+midY && y < 2*h+midY+stroke))
                            let vertical = y >= midY && y < 2*h+midY+stroke &&
                                ((x >= midX && x < midX+stroke) ||
                                 (x >= 4*w+midX && x < 4*w+midX+stroke))
                            if !horizontal && !vertical {
                                #expect(!ink(x, y), "border spur at \(x),\(y), size \(size), scale \(scale)")
                            }
                        }
                    }

                }
            }
        }
    }

    /// Claude Code draws its boxes with ╭╮╰╯. Drawn from the font, the
    /// corners neither met the grid-drawn sides nor matched their weight:
    /// every rounded box had four broken corners. The border must be one
    /// connected stroke, through every corner.
    @Test func roundedCornersJoinTheirSides() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        for size: CGFloat in [12, 14, 17, 40] {
            for scale: CGFloat in [1, 1.25, 1.5, 2, 3] {
                let renderer = try TerminalRenderer(device: device,
                    font: TerminalFont.primary(ofSize: size), scale: scale)
                var terminal = Terminal(rows: 3, columns: 5)
                terminal.feed(Array("\u{1B}[37m╭───╮\r\n│   │\r\n╰───╯".utf8))
                let w = Int(renderer.metrics.cellWidth), h = Int(renderer.metrics.cellHeight)
                let width = 5 * w, height = 3 * h
                let texture = MetalRenderTarget.make(device: device, width: width, height: height)
                renderer.renderAndWait(grid: terminal.grid,
                    rect: CGRect(x: 0, y: 0, width: width, height: height),
                    drawableSize: CGSize(width: width, height: height), cursorVisible: false,
                    selection: nil, target: texture)
                var bytes = [UInt8](repeating: 0, count: width * height * 4)
                texture.getBytes(&bytes, bytesPerRow: width * 4,
                    from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                func ink(_ x: Int, _ y: Int) -> Bool {
                    let i = (y * width + x) * 4
                    return Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2]) > 100
                }
                let stroke = max(1, Int(scale))
                let midX = (w - stroke) / 2, midY = (h - stroke) / 2
                // Every ink pixel reachable from the middle of the top side.
                var seen = [Bool](repeating: false, count: width * height)
                var queue = [(2 * w, midY)]
                seen[midY * width + 2 * w] = true
                while let (x, y) = queue.popLast() {
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let nx = x + dx, ny = y + dy
                            guard nx >= 0, ny >= 0, nx < width, ny < height,
                                !seen[ny * width + nx], ink(nx, ny) else { continue }
                            seen[ny * width + nx] = true
                            queue.append((nx, ny))
                        }
                    }
                }
                if size == 17 && scale == 2 {
                    MetalRenderTarget.attachPNG(texture, named: "rounded-table-corners-17-2.png")
                }
                let context = "size \(size), scale \(scale)"
                #expect(seen[(h + h / 2) * width + midX], "left side cut off, \(context)")
                #expect(seen[(h + h / 2) * width + 4 * w + midX], "right side cut off, \(context)")
                #expect(seen[(2 * h + midY) * width + 2 * w], "bottom side cut off, \(context)")
                // A corner is a curve, not a square: its cell's outer corner is bare.
                for (x, y) in [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)] {
                    #expect(!ink(x, y), "ink in a rounded corner at \(x),\(y), \(context)")
                }
                if !(seen[(h + h / 2) * width + midX] && seen[(h + h / 2) * width + 4 * w + midX]) {
                    MetalRenderTarget.attachPNG(texture, named: "rounded-box-\(Int(size))-\(Int(scale)).png")
                }
            }
        }
    }

    /// Every corner's pieces stay inside the cell and inside the inline storage.
    @Test func roundedCornerPiecesStayInTheirCell() {
        for scalar: UInt32 in 0x256D...0x2570 {
            for (width, height, scale): (Float, Float, Float) in
                [(7, 15, 1), (17, 33, 2), (60, 120, 2), (115, 230, 3), (2, 4, 1)] {
                let pieces = try? #require(BoxDrawing.pieces(for: scalar, width: width,
                    height: height, scale: scale))
                guard let pieces else { continue }
                #expect(pieces.count <= BoxDrawing.capacity)
                for rect in pieces {
                    #expect(rect.x >= 0 && rect.y >= 0 && rect.z > 0 && rect.w > 0)
                    #expect(rect.x + rect.z <= width && rect.y + rect.w <= height,
                        "U+\(String(scalar, radix: 16)) \(rect) outside \(width)x\(height)")
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
