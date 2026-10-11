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

import simd

/// Block elements (U+2580–U+259F) drawn as geometry, not glyphs. A cell is
/// the advance snapped to device pixels (`CellMetrics`), and a font's block
/// glyphs rarely fill it exactly: measured, `U+2588 FULL BLOCK` once inked
/// 88% of its cell, turning (255,140,0) orange pink with the background
/// showing through — how Claude Code's banner looked. kitty, Ghostty and
/// Alacritty synthesise the range too: rectangles in unit cell space, scaled
/// at draw time, so they meet exactly.
nonisolated enum BlockElements {
    /// A rectangle in unit cell space (y down, as the shader) and its
    /// coverage.
    struct Piece {
        var rect: SIMD4<Float>
        var alpha: Float
    }

    /// Up to three pieces, stored inline: a block element on every cell of
    /// a progress bar must not allocate an array per cell per rebuild.
    struct Pieces: RandomAccessCollection {
        private var storage = InlineArray<3, Piece>(repeating: Piece(rect: .zero, alpha: 0))
        private(set) var endIndex = 0

        var startIndex: Int { 0 }

        subscript(position: Int) -> Piece { storage[position] }

        fileprivate init() {}

        fileprivate init(_ x: Float, _ y: Float, _ w: Float, _ h: Float, _ a: Float = 1) {
            append(x, y, w, h, a)
        }

        fileprivate mutating func append(
            _ x: Float, _ y: Float, _ w: Float, _ h: Float, _ a: Float = 1
        ) {
            storage[endIndex] = Piece(rect: SIMD4<Float>(x, y, w, h), alpha: a)
            endIndex += 1
        }
    }

    /// Nil for a scalar that isn't a block element.
    static func pieces(for scalar: UInt32) -> Pieces? {
        switch scalar {
        case 0x2580: return Pieces(0, 0, 1, 0.5)            // ▀ upper half
        case 0x2581...0x2587:                               // ▁▂▃▄▅▆▇ lower eighths
            let eighths = Float(scalar - 0x2580)
            let h = eighths / 8
            return Pieces(0, 1 - h, 1, h)
        case 0x2588: return Pieces(0, 0, 1, 1)              // █ full
        case 0x2589...0x258F:                               // ▉▊▋▌▍▎▏ left eighths
            let w = Float(0x2590 - scalar) / 8
            return Pieces(0, 0, w, 1)
        case 0x2590: return Pieces(0.5, 0, 0.5, 1)          // ▐ right half
        case 0x2591: return Pieces(0, 0, 1, 1, 0.25)        // ░ light shade
        case 0x2592: return Pieces(0, 0, 1, 1, 0.5)         // ▒ medium shade
        case 0x2593: return Pieces(0, 0, 1, 1, 0.75)        // ▓ dark shade
        case 0x2594: return Pieces(0, 0, 1, 0.125)          // ▔ upper eighth
        case 0x2595: return Pieces(0.875, 0, 0.125, 1)      // ▕ right eighth
        case 0x2596...0x259F:                               // quadrants
            // Bit per quadrant: 1 = upper left, 2 = upper right,
            // 4 = lower left, 8 = lower right; four bits per scalar, from
            // U+2596 in the low nibble.
            let masks: UInt64 = 0xE6_2B79_D184
            let mask = UInt8(truncatingIfNeeded: masks >> (4 * UInt64(scalar - 0x2596))) & 0xF
            var out = Pieces()
            if mask & 0b0001 != 0 { out.append(0, 0, 0.5, 0.5) }
            if mask & 0b0010 != 0 { out.append(0.5, 0, 0.5, 0.5) }
            if mask & 0b0100 != 0 { out.append(0, 0.5, 0.5, 0.5) }
            if mask & 0b1000 != 0 { out.append(0.5, 0.5, 0.5, 0.5) }
            return out
        default: return nil
        }
    }
}


/// Common light/heavy table borders are pixel-aligned strokes that reach
/// their cell edges. Font bearings and fallback advances cannot open gaps.
/// The rounded corners ╭╮╯╰ — Claude Code's boxes — are drawn the same way:
/// a font's arc neither meets these strokes nor shares their weight.
nonisolated enum BoxDrawing {
    /// Room for an arc's rows: `arc` coarsens its step to stay inside it.
    static let capacity = 24

    struct Pieces: RandomAccessCollection {
        private var storage = InlineArray<24, SIMD4<Float>>(repeating: .zero)
        private(set) var endIndex = 0
        var startIndex: Int { 0 }
        subscript(position: Int) -> SIMD4<Float> { storage[position] }
        mutating func append(_ rect: SIMD4<Float>) {
            storage[endIndex] = rect
            endIndex += 1
        }
    }

    static func pieces(for scalar: UInt32, width: Float, height: Float, scale: Float) -> Pieces? {
        // left, right, up, down. The common solid U+2500–U+254B
        // characters encode each arm as absent/light/heavy.
        let arms: UInt8
        switch scalar {
        case 0x2500: arms = 0x05
        case 0x2501: arms = 0x0A
        case 0x2502: arms = 0x50
        case 0x2503: arms = 0xA0
        case 0x250C...0x254B:
            // Four two-bit arm weights, from Unicode's character names.
            let values: InlineArray<64, UInt8> = [
                0x44,0x48,0x84,0x88, 0x41,0x42,0x81,0x82,
                0x14,0x18,0x24,0x28, 0x11,0x12,0x21,0x22,
                0x54,0x58,0x64,0x94,0xA4,0x68,0x98,0xA8,
                0x51,0x52,0x61,0x91,0xA1,0x62,0x92,0xA2,
                0x45,0x46,0x49,0x4A,0x85,0x86,0x89,0x8A,
                0x15,0x16,0x19,0x1A,0x25,0x26,0x29,0x2A,
                0x55,0x56,0x59,0x5A,0x65,0x95,0xA5,0x66,
                0x69,0x96,0x99,0x6A,0x9A,0xA6,0xA9,0xAA
            ]
            arms = values[Int(scalar - 0x250C)]
        case 0x2574...0x2577: arms = UInt8(1 << ((scalar - 0x2574) * 2))
        case 0x2578...0x257B: arms = UInt8(2 << ((scalar - 0x2578) * 2))
        case 0x257C: arms = 0x09
        case 0x257D: arms = 0x90
        case 0x257E: arms = 0x06
        case 0x257F: arms = 0x60
        case 0x256D...0x2570:
            return arc(corner: Int(scalar - 0x256D), width: width, height: height, scale: scale)
        default: return nil
        }
        var pieces = Pieces()
        let light = max(1, scale.rounded(.down))
        // Join at the widest perpendicular stroke. Extending past that
        // stroke makes square corners sprout pixels outside their border.
        let verticalWeight = max((arms >> 4) & 3, (arms >> 6) & 3)
        let horizontalWeight = max(arms & 3, (arms >> 2) & 3)
        let verticalThickness = min(min(width, height), light * Float(verticalWeight))
        let horizontalThickness = min(min(width, height), light * Float(horizontalWeight))
        let joinX = ((width - verticalThickness) / 2).rounded(.down)
        let joinY = ((height - horizontalThickness) / 2).rounded(.down)
        for direction in 0..<4 {
            let weight = (arms >> (direction * 2)) & 3
            guard weight != 0 else { continue }
            let thickness = min(min(width, height), light * Float(weight))
            let x = ((width - thickness) / 2).rounded(.down)
            let y = ((height - thickness) / 2).rounded(.down)
            switch direction {
            case 0: pieces.append(.init(0, y, joinX + verticalThickness, thickness))
            case 1: pieces.append(.init(joinX, y, width - joinX, thickness))
            case 2: pieces.append(.init(x, 0, thickness, joinY + horizontalThickness))
            default: pieces.append(.init(x, joinY, thickness, height - joinY))
            }
        }
        return pieces
    }

    /// U+256D–2570, in order ╭ ╮ ╯ ╰: a light quarter circle joining two arms
    /// at exactly the position and weight the straight strokes use, so a
    /// rounded box meets its sides. The arc is rasterised one pixel row per
    /// rectangle — aliased, like the strokes it joins.
    private static func arc(corner: Int, width: Float, height: Float, scale: Float) -> Pieces {
        let thickness = min(min(width, height), max(1, scale.rounded(.down)))
        let x0 = ((width - thickness) / 2).rounded(.down)
        let y0 = ((height - thickness) / 2).rounded(.down)
        // The strokes' centre lines, where the arc starts and ends.
        let kx = x0 + thickness / 2, ky = y0 + thickness / 2
        let rightward = corner == 0 || corner == 3
        let downward = corner == 0 || corner == 1
        let radius = max(thickness, min(min(kx, width - kx), min(ky, height - ky)).rounded(.down))
        let cx = rightward ? kx + radius : kx - radius
        let cy = downward ? ky + radius : ky - radius

        var pieces = Pieces()
        // Arms start on a whole pixel, rounded toward the arc so they overlap
        // it: a centre on a half pixel left a half-pixel arm that drew nothing.
        if rightward {
            let start = cx.rounded(.down)
            if start < width { pieces.append(.init(start, y0, width - start, thickness)) }
        } else {
            let end = min(width, cx.rounded(.up))
            if end > 0 { pieces.append(.init(0, y0, end, thickness)) }
        }
        if downward {
            let start = cy.rounded(.down)
            if start < height { pieces.append(.init(x0, start, thickness, height - start)) }
        } else {
            let end = min(height, cy.rounded(.up))
            if end > 0 { pieces.append(.init(x0, 0, thickness, end)) }
        }

        let outer = radius + thickness / 2, inner = max(0, radius - thickness / 2)
        // Rows from the arc's far end (the horizontal arm) to its centre row.
        let top = max(0, downward ? (cy - outer).rounded(.down) : cy.rounded(.down))
        let bottom = min(height, downward ? cy.rounded(.up) : (cy + outer).rounded(.up))
        let rows = max(1, Int(bottom - top))
        let step = Float((rows + capacity - 3) / (capacity - 2))
        var y = top
        while y < bottom, pieces.endIndex < capacity {
            let band = min(step, bottom - y)
            let distance = abs(y + band / 2 - cy)
            if distance <= outer {
                let far = (outer * outer - distance * distance).squareRoot()
                let near = distance < inner ? (inner * inner - distance * distance).squareRoot() : 0
                // Toward the corner of the strokes, away from the centre.
                let a = rightward ? cx - far : cx + near
                let b = rightward ? cx - near : cx + far
                let left = max(0, a.rounded())
                let right = min(width, max(a.rounded() + 1, b.rounded()))
                if right > left { pieces.append(.init(left, y, right - left, band)) }
            }
            y += band
        }
        return pieces
    }
}
