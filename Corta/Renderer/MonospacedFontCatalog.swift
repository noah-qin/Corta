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
import CoreText

/// Which installed families a grid can actually lay out (D12). The
/// renderer assumes every glyph in the regular, bold, italic and
/// bold-italic faces advances exactly one cell, which `isFixedPitch`
/// doesn't promise. Common failures: a wider bold face, digits or
/// box-drawing off the grid, and bitmap or colour faces with no outlines.
///
/// Since D11 only System Monospaced is offered, so this checks the family a
/// hand-edited config names rather than listing what is installed.
nonisolated enum MonospacedFontCatalog {
    /// Advances scale linearly; this only sets the tolerance's units.
    private static let measurementSize: CGFloat = 12
    /// True monospace varies far less; "mostly fixed" misses by tenths.
    private static let tolerance: CGFloat = 0.01

    /// Printable ASCII: prompts, borders and numbers.
    private static let measuredCharacters: [UniChar] = (0x20...0x7E).map(UniChar.init)

    /// An outline face with uniform ASCII advances that its bold, italic and
    /// bold-italic faces keep. A missing italic passes (the regular face is
    /// used and sheared); only faces that exist and disagree fail.
    static func isUsable(family: String) -> Bool {
        guard
            let base = NSFont(
                descriptor: NSFontDescriptor(fontAttributes: [.family: family]),
                size: measurementSize),
            let advance = uniformAdvance(of: base as CTFont)
        else { return false }
        let derivations: [CTFontSymbolicTraits] = [
            .traitBold, .traitItalic, [.traitBold, .traitItalic],
        ]
        for traits in derivations {
            let derived =
                CTFontCreateCopyWithSymbolicTraits(base as CTFont, 0, nil, traits, traits)
                ?? (base as CTFont)
            guard let derivedAdvance = uniformAdvance(of: derived),
                abs(derivedAdvance - advance) <= tolerance
            else { return false }
        }
        return true
    }

    /// The shared ASCII advance, or nil if not outline, incomplete or uneven.
    static func uniformAdvance(of font: CTFont) -> CGFloat? {
        guard hasOutlines(font) else { return nil }
        var characters = measuredCharacters
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        // False if any character is unmapped.
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
        else { return nil }
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advances, glyphs.count)
        guard let first = advances.first?.width, first > 0 else { return nil }
        for advance in advances where abs(advance.width - first) > tolerance { return nil }
        return first
    }

    /// Scalable outlines, not bitmap strikes (smeared at other sizes) or
    /// colour (never reaches the coverage atlas).
    private static func hasOutlines(_ font: CTFont) -> Bool {
        guard !CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) else { return false }
        // `glyf` (TrueType), `CFF ` or `CFF2` (PostScript).
        let outlineTables: [CTFontTableTag] = [
            CTFontTableTag(kCTFontTableGlyf),
            CTFontTableTag(kCTFontTableCFF),
            0x4346_4632,  // 'CFF2'
        ]
        return outlineTables.contains { CTFontCopyTable(font, $0, []) != nil }
    }
}
