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

import Foundation
import CoreText
import Synchronization

/// Which installed families a grid can actually lay out (D12). The
/// renderer assumes every glyph in the regular, bold, italic and
/// bold-italic faces advances exactly one cell, which `isFixedPitch`
/// doesn't promise. Common failures: a wider bold face, digits or
/// box-drawing off the grid, and bitmap or colour faces with no outlines.
///
/// Families come from Core Text, so installed fonts appear, and are verified
/// on the faces Corta uses. Measuring hundreds is slow, so the list and each
/// family's verdict are cached; `refresh()` drops both.
nonisolated enum MonospacedFontCatalog {
    /// Where a family's file lives, which is what the picker groups by.
    enum Origin: Sendable, Equatable {
        /// Under `/System/Library`: shipped with macOS, or one of Apple's
        /// on-demand fonts already downloaded.
        case apple
        /// Anywhere else — `~/Library/Fonts`, `/Library/Fonts`.
        case user(path: String)
    }

    struct Entry: Sendable, Equatable {
        let name: String
        let origin: Origin
        /// Carries its own Han, kana or Hangul, so its letters and symbols
        /// follow a CJK design (a raised `~`, curly quotes).
        let hasCJK: Bool
    }

    /// Advances scale linearly; this only sets the tolerance's units.
    private static let measurementSize: CGFloat = 12
    /// True monospace varies far less; "mostly fixed" misses by tenths.
    private static let tolerance: CGFloat = 0.01

    /// Printable ASCII: prompts, borders and numbers.
    private static let measuredCharacters: [UniChar] = (0x20...0x7E).map(UniChar.init)

    /// 日, あ, 한: one each of Han, kana and Hangul.
    private static let cjkProbes: [UniChar] = [0x65E5, 0x3042, 0xD55C]

    private struct Cache {
        var entries: [Entry]?
        /// `isUsable` by family: `primary` asks on every frame that draws a
        /// shell overlay, and a picker change asks once per pane.
        var usable: [String: Bool] = [:]
        /// Bumped by `refresh()`, so a scan that began before it is not kept.
        var generation = 0
    }

    /// The list is filled off the main thread by the settings page; the lock
    /// is never held while measuring, so `refresh()` on the main thread
    /// does not wait out a scan.
    private static let cache = Mutex(Cache())

    /// The installed families the grid can lay out, sorted for a picker.
    static func entries() -> [Entry] {
        let (cached, generation) = cache.withLock { ($0.entries, $0.generation) }
        if let cached { return cached }
        // Core Text, not `NSFontManager`, which is AppKit's to use on the
        // main thread. Names starting with "." are private system faces.
        let names = (CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])
            .filter { !$0.hasPrefix(".") }
        let entries = Set(names).sorted().filter(isUsable(family:)).compactMap(entry(for:))
        cache.withLock { if $0.generation == generation { $0.entries = entries } }
        return entries
    }

    static func families() -> [String] { entries().map(\.name) }

    /// Describes an installed family; nil when none is.
    static func entry(for family: String) -> Entry? {
        guard let font = font(ofFamily: family) else { return nil }
        let path = (CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)?.path ?? ""
        let origin: Origin = path.hasPrefix("/System/Library/") ? .apple : .user(path: path)
        let hasCJK = cjkProbes.contains { probe in
            var character = probe
            var glyph = CGGlyph(0)
            return CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        }
        return Entry(name: family, origin: origin, hasCJK: hasCJK)
    }

    /// Forgets the list and the verdicts, for when the installed fonts change.
    static func refresh() {
        cache.withLock { $0 = Cache(generation: $0.generation + 1) }
    }

    /// An outline face with uniform ASCII advances that its bold, italic and
    /// bold-italic faces keep. A missing italic passes (the regular face is
    /// used and sheared); only faces that exist and disagree fail.
    static func isUsable(family: String) -> Bool {
        let (known, generation) = cache.withLock { ($0.usable[family], $0.generation) }
        if let known { return known }
        let usable = font(ofFamily: family).map(measure(base:)) ?? false
        cache.withLock { if $0.generation == generation { $0.usable[family] = usable } }
        return usable
    }

    /// The same check for one face of a family — a Light or Medium that
    /// `font-weight` picks, with the bold and italic derived from it.
    static func isUsable(face: CTFont) -> Bool {
        // Keyed apart from family names: a PostScript name has no spaces,
        // but a family may be called anything.
        let key = "\u{0}" + (CTFontCopyPostScriptName(face) as String)
        let (known, generation) = cache.withLock { ($0.usable[key], $0.generation) }
        if let known { return known }
        let usable = measure(base: CTFontCreateCopyWithAttributes(face, measurementSize, nil, nil))
        cache.withLock { if $0.generation == generation { $0.usable[key] = usable } }
        return usable
    }

    private static func measure(base: CTFont) -> Bool {
        guard let advance = uniformAdvance(of: base) else { return false }
        let derivations: [CTFontSymbolicTraits] = [
            .traitBold, .traitItalic, [.traitBold, .traitItalic],
        ]
        for traits in derivations {
            let derived =
                CTFontCreateCopyWithSymbolicTraits(base, 0, nil, traits, traits) ?? base
            guard let derivedAdvance = uniformAdvance(of: derived),
                abs(derivedAdvance - advance) <= tolerance
            else { return false }
        }
        return true
    }

    /// The family's default face, through Core Text: the catalog runs off
    /// the main thread. A descriptor for an unknown family still matches
    /// some other face, so the answer's family is checked.
    private static func font(ofFamily family: String) -> CTFont? {
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontFamilyNameAttribute: family] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, measurementSize, nil)
        return CTFontCopyFamilyName(font) as String == family ? font : nil
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
