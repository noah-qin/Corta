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
