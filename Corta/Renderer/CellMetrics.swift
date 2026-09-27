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

/// The cell box and baseline a monospaced font imposes, derived once per
/// font.
nonisolated struct CellMetrics {
    var cellWidth: CGFloat
    var cellHeight: CGFloat
    /// From the cell's top down to the baseline.
    var baselineOffset: CGFloat

    /// The box in device pixels, by multiplication, so it never drifts from
    /// the point grid.
    func scaled(by scale: CGFloat) -> CellMetrics {
        var copy = self
        copy.cellWidth *= scale
        copy.cellHeight *= scale
        copy.baselineOffset *= scale
        return copy
    }

    /// - Parameter scale: the backing scale. The box snaps to whole device
    ///   pixels, not points: point snapping (SF Mono's 0.6 advance gave 9pt at
    ///   both 14pt and 15pt) made font steps change the window's aspect
    ///   unevenly.
    init(font: CTFont, scale: CGFloat = 1) {
        // Ask the font rather than assume: some are only mostly fixed.
        var glyph: CGGlyph = 0
        var mChar: UniChar = UniChar(UnicodeScalar("M").value)
        CTFontGetGlyphsForCharacters(font, &mChar, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)

        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)

        let pixels = max(1, scale)
        func snapUp(_ points: CGFloat) -> CGFloat { (points * pixels).rounded(.up) / pixels }
        func snapNearest(_ points: CGFloat) -> CGFloat { (points * pixels).rounded() / pixels }

        let advanceWidth = advance.width > 0 ? advance.width : CTFontGetSize(font) * 0.6
        let lineHeight = ascent + descent + leading

        // Snap down by at most a device pixel, matching Terminal.app's 7pt
        // column for SF Mono 12 (nominal 7.418pt); rounding up widened 120
        // columns by 60pt and stretched cell-built artwork. The ink is
        // narrower than the advance, so cells don't collide.
        self.cellWidth = max(1 / pixels, (advanceWidth * pixels).rounded(.down) / pixels)
        // Height follows the font's line metrics, independent of width. Never
        // zero: empty metrics once trapped `gridSize(fitting:)` with `inf`.
        self.cellHeight = max(1 / pixels, snapUp(lineHeight))
        // Split the leading evenly, keeping the glyph centred.
        self.baselineOffset = snapNearest(ascent + (cellHeight - lineHeight) / 2)
    }
}
