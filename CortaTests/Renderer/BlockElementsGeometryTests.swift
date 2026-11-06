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

import Testing

@testable import Corta

/// The block-element table as data: each quadrant scalar lights the
/// quadrants Unicode names for it, and every scalar in U+2580–U+259F has
/// pieces while its neighbours have none.
struct BlockElementsGeometryTests {
    /// Bit per quadrant: 1 = upper left, 2 = upper right, 4 = lower left,
    /// 8 = lower right — from the code chart's names, U+2596 to U+259F.
    private static let quadrants: [UInt8] = [
        0b0100, 0b1000, 0b0001, 0b1101, 0b1001, 0b0111, 0b1011, 0b0010, 0b0110, 0b1110,
    ]

    @Test func quadrantsLightTheNamedCorners() throws {
        for (offset, expected) in Self.quadrants.enumerated() {
            let pieces = try #require(BlockElements.pieces(for: 0x2596 + UInt32(offset)))
            var mask: UInt8 = 0
            for piece in pieces {
                #expect(piece.rect.z == 0.5 && piece.rect.w == 0.5 && piece.alpha == 1)
                mask |= (piece.rect.x == 0 ? 1 : 2) << (piece.rect.y == 0 ? 0 : 2)
            }
            #expect(mask == expected, "U+\(String(0x2596 + offset, radix: 16, uppercase: true))")
            #expect(pieces.count == expected.nonzeroBitCount)
        }
    }

    @Test func theRangeAndOnlyTheRangeHasPieces() {
        for scalar in UInt32(0x2580)...0x259F {
            #expect(BlockElements.pieces(for: scalar)?.isEmpty == false)
        }
        #expect(BlockElements.pieces(for: 0x257F) == nil)
        #expect(BlockElements.pieces(for: 0x25A0) == nil)
        #expect(BlockElements.pieces(for: 0x41) == nil)
    }

    @Test func eighthsAndShadesKeepTheirGeometry() throws {
        let lowerThreeEighths = try #require(BlockElements.pieces(for: 0x2583))
        #expect(lowerThreeEighths.count == 1)
        #expect(lowerThreeEighths[0].rect == SIMD4<Float>(0, 1 - 3.0 / 8, 1, 3.0 / 8))
        let mediumShade = try #require(BlockElements.pieces(for: 0x2592))
        #expect(mediumShade[0].rect == SIMD4<Float>(0, 0, 1, 1) && mediumShade[0].alpha == 0.5)
    }
}
