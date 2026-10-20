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
import Synchronization

/// The font stack: System Monospaced (tracking the OS), then one CJK face
/// per script — PingFang SC, PingFang TC, Hiragino Sans, Apple SD Gothic
/// Neo, the user's language first — and Apple Color Emoji, pinned as
/// `kCTFontCascadeListAttribute`, so fallback follows the language rather
/// than whatever Core Text's own search reaches first. Kana and Hangul lead
/// with their own face whatever the language (`GlyphAtlas.shape`). A CJK
/// family the user chose (`font-family-cjk`) goes before all of them.
///
/// `CTFontCreateCopyWithSymbolicTraits` drops the cascade list, while
/// `CTFontCreateCopyWithAttributes` keeps it (observed, not documented),
/// so every derivation that matters re-pins it.
nonisolated enum TerminalFont {
    /// The CJK face that leads the cascade. Han characters are shared across
    /// the four scripts and drawn differently in each, so which face comes
    /// first decides the shape of 直 or 骨.
    enum CJKLead: CaseIterable, Sendable {
        case simplifiedChinese, traditionalChinese, japanese, korean

        /// From the first preferred language: Traditional for zh-Hant and
        /// the regions that write it, Japanese for ja, Korean for ko,
        /// Simplified Chinese otherwise.
        static func forLanguages(_ languages: [String]) -> CJKLead {
            guard let first = languages.first?.lowercased() else { return .simplifiedChinese }
            if first.hasPrefix("ja") { return .japanese }
            if first.hasPrefix("ko") { return .korean }
            if first.hasPrefix("zh-hant") || ["zh-tw", "zh-hk", "zh-mo"].contains(where: first.hasPrefix) {
                return .traditionalChinese
            }
            return .simplifiedChinese
        }

        /// PostScript names: regular, and the face under a real bold.
        /// Semibold, not Bold, beside SF Mono's Semibold bold.
        var faces: (regular: String, bold: String) {
            switch self {
            case .simplifiedChinese: ("PingFangSC-Regular", "PingFangSC-Semibold")
            case .traditionalChinese: ("PingFangTC-Regular", "PingFangTC-Semibold")
            case .japanese: ("HiraginoSans-W3", "HiraginoSans-W6")
            case .korean: ("AppleSDGothicNeo-Regular", "AppleSDGothicNeo-SemiBold")
            }
        }
    }

    /// The user's language's lead, read once: a language change takes a
    /// relaunch, as it does for the rest of the app.
    static let localeLead = CJKLead.forLanguages(Locale.preferredLanguages)

    /// The cascade, in order — the chosen CJK family if it is usable, then
    /// `lead`, the other scripts in `CJKLead.allCases` order, then emoji.
    /// Fallbacks take the primary's size.
    static func cascade(lead: CJKLead, bold: Bool, cjk: String? = nil) -> [CTFontDescriptor] {
        let lists = cascades[lead]!
        let base = bold ? lists.bold : lists.regular
        guard let cjk, let chosen = chosenCJKFaces(cjk) else { return base }
        return [bold ? chosen.bold : chosen.regular] + base
    }

    /// A chosen CJK family's regular and bold faces, as cascade entries. Its
    /// own bold when it has one, else its regular: CJK is never stroked.
    private struct ChosenFaces: @unchecked Sendable {
        let regular: CTFontDescriptor
        let bold: CTFontDescriptor
        /// The catalog's generation they were resolved in: a font install
        /// or removal can rename or remove the faces.
        let generation: Int
    }

    /// Resolved once per family and catalog generation; only a usable family
    /// is kept, so one installed later resolves on the next ask.
    private static let chosenFaces = Mutex<[String: ChosenFaces]>([:])

    /// What a chosen CJK family may draw: Han, kana, Hangul, bopomofo, CJK
    /// punctuation and fullwidth forms. Without the limit it took every
    /// character the primary lacks — a prompt's `★` or `✓`, an emoji's text
    /// form — in a face never checked against the grid.
    private nonisolated(unsafe) static let cjkCharacters: CFCharacterSet = {
        let set = CFCharacterSetCreateMutable(nil)!
        let ranges: [ClosedRange<Int>] = [
            0x1100...0x11FF,  // Hangul Jamo
            0x2E80...0x2FFF,  // CJK and Kangxi radicals, ideographic description
            0x3000...0x303F,  // CJK symbols and punctuation
            0x3040...0x31FF,  // kana, bopomofo, Hangul compatibility Jamo, kanbun, strokes
            0x3200...0x33FF,  // enclosed CJK, CJK compatibility
            0x3400...0x4DBF,  // extension A
            0x4E00...0x9FFF,  // unified ideographs
            0xA960...0xA97F,  // Hangul Jamo extended A
            0xAC00...0xD7FF,  // Hangul syllables, Jamo extended B
            0xF900...0xFAFF,  // compatibility ideographs
            0xFE30...0xFE4F,  // CJK compatibility forms
            0xFF00...0xFFEF,  // halfwidth and fullwidth forms
            0x1B000...0x1B16F,  // kana supplement and extended
            0x20000...0x323AF,  // extensions B to H, compatibility supplement
        ]
        for range in ranges {
            CFCharacterSetAddCharactersInRange(
                set, CFRange(location: range.lowerBound, length: range.count))
        }
        return set
    }()

    private static func chosenCJKFaces(_ family: String) -> ChosenFaces? {
        let generation = MonospacedFontCatalog.generation
        if let known = chosenFaces.withLock({ $0[family] }), known.generation == generation { return known }
        guard MonospacedFontCatalog.isUsableCJK(family: family),
            let regular = MonospacedFontCatalog.font(ofFamily: family)
        else { return nil }
        let bold = CTFontCreateCopyWithSymbolicTraits(regular, 0, nil, .traitBold, .traitBold)
            .flatMap { CTFontCopyFamilyName($0) as String == family ? $0 : nil } ?? regular
        func entry(_ font: CTFont) -> CTFontDescriptor {
            CTFontDescriptorCreateWithAttributes(
                [
                    kCTFontNameAttribute: CTFontCopyPostScriptName(font),
                    kCTFontCharacterSetAttribute: cjkCharacters,
                ] as CFDictionary)
        }
        let faces = ChosenFaces(regular: entry(regular), bold: entry(bold), generation: generation)
        chosenFaces.withLock { $0[family] = faces }
        return faces
    }

    /// Every lead's two lists, built once: `pinningCascadeList` runs for
    /// each style on every ⌘= / ⌘- repeat. Immutable, hence
    /// `nonisolated(unsafe)` for the non-`Sendable` descriptors.
    private nonisolated(unsafe) static let cascades: [CJKLead: (regular: [CTFontDescriptor], bold: [CTFontDescriptor])] =
        Dictionary(uniqueKeysWithValues: CJKLead.allCases.map { lead in
            let order = [lead] + CJKLead.allCases.filter { $0 != lead }
            func list(bold: Bool) -> [CTFontDescriptor] {
                (order.map { bold ? $0.faces.bold : $0.faces.regular } + ["AppleColorEmoji"])
                    .map { CTFontDescriptorCreateWithNameAndSize($0 as CFString, 0) }
            }
            return (lead, (list(bold: false), list(bold: true)))
        })

    /// System Monospaced's weight: Regular, like every other family and the
    /// fallbacks, so text and its CJK and symbol fallbacks share one weight.
    /// SF Mono alone was once Medium, to look as dense as Terminal.app; that
    /// left PingFang and every chosen family a step lighter beside it. No face
    /// is thickened: a stroke matching Medium's ink, or system font smoothing
    /// (heavier still), read heavier than the faces as drawn.
    static let systemWeight: NSFont.Weight = .regular

    /// The primary font, cascade pinned.
    ///
    /// - Parameter size: in points.
    /// - Parameter family: nil for System Monospaced. A family that isn't
    ///   installed or that `MonospacedFontCatalog` rejects falls back to the
    ///   system font — the config file can name anything (D12).
    /// - Parameter weight: a family without that face draws its Regular.
    /// - Parameter cjk: a CJK family to put first in the cascade; nil, or
    ///   one that is not installed, follows the system language.
    static func primary(
        ofSize size: CGFloat, family: String? = nil, weight: Configuration.FontWeight = .regular,
        cjk: String? = nil
    ) -> CTFont {
        if let family, family != Configuration.systemFontFamily,
            MonospacedFontCatalog.isUsable(family: family),
            let font = weighted(family, weight, size: size) ?? namedFamily(family, size: size)
        {
            return pinningCascadeList(font as CTFont, size: size, cjk: cjk)
        }
        let system = NSFont.monospacedSystemFont(ofSize: size, weight: weight.systemWeight) as CTFont
        return pinningCascadeList(system, size: size, cjk: cjk)
    }

    /// The family's face at exactly `weight`, or nil: `NSFontManager`
    /// answers the nearest face, and a Bold for "medium" is not one. The
    /// face is verified as the family was (D12): passing for Regular says
    /// nothing about a Light's advances.
    private static func weighted(_ family: String, _ weight: Configuration.FontWeight, size: CGFloat) -> NSFont? {
        guard weight != .regular,
            let font = NSFontManager.shared.font(
                withFamily: family, traits: [], weight: weight.managerWeight, size: size),
            font.familyName == family,
            NSFontManager.shared.weight(of: font) == weight.managerWeight,
            MonospacedFontCatalog.isUsable(face: font as CTFont)
        else { return nil }
        return font
    }

    /// Resolves a family name ("Menlo"). Not `NSFont(name:)`, which also
    /// takes a face ("Menlo-Bold") that `isUsable` never measured.
    private static func namedFamily(_ family: String, size: CGFloat) -> NSFont? {
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
        return NSFont(descriptor: descriptor, size: size)
    }

    /// Why `primary` would not use a configured family.
    enum FontResolution: Equatable {
        case resolved
        case missing(requested: String)
        case invalidForGrid(requested: String)
    }

    /// What `primary` does with `family`, for the settings page to explain
    /// a fallback instead of leaving it silent.
    static func resolution(forFamily family: String?) -> FontResolution {
        guard let family, family != Configuration.systemFontFamily else { return .resolved }
        // Not `namedFamily`: a descriptor for an unknown family still
        // matches some other face, which would report "uneven" instead. A
        // face name ("JetBrainsMono-Regular") is not a family either.
        guard NSFontManager.shared.availableMembers(ofFontFamily: family) != nil else {
            return .missing(requested: family)
        }
        guard MonospacedFontCatalog.isUsable(family: family) else {
            return .invalidForGrid(requested: family)
        }
        return .resolved
    }

    /// A styled variant for the atlas, and whether its bold is synthetic.
    /// Neither style may vanish: a missing italic is sheared (advance
    /// unchanged), and a missing bold is stroked at rasterisation, hence the
    /// flag. The trait copy drops the cascade, so it is re-pinned here, or
    /// bold CJK would skip PingFang SC.
    static func variant(of font: CTFont, bold: Bool, italic: Bool, cjk: String? = nil)
        -> (font: CTFont, syntheticBold: Bool)
    {
        let size = CTFontGetSize(font)
        guard bold || italic else { return (pinningCascadeList(font, size: size, cjk: cjk), false) }

        var desired: CTFontSymbolicTraits = []
        if bold { desired.insert(.traitBold) }
        if italic { desired.insert(.traitItalic) }
        let derived =
            CTFontCreateCopyWithSymbolicTraits(font, 0, nil, desired, desired) ?? font
        let actual = CTFontGetSymbolicTraits(derived)

        var styled = derived
        // No italic face: the usual ~12° oblique (tan 12° ≈ 0.21).
        if italic, !actual.contains(.traitItalic) {
            var matrix = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)
            styled = CTFontCreateCopyWithAttributes(derived, 0, &matrix, nil)
        }
        return (
            pinningCascadeList(styled, size: size, cjk: cjk),
            bold && !actual.contains(.traitBold)
        )
    }

    /// Re-applies the pinned cascade, the bold one under a real bold face;
    /// idempotent. A synthetic bold keeps the regular cascade: its stroke
    /// already thickens the fallback glyphs too.
    ///
    /// A copy of the font in hand, not a font resolved again from its
    /// descriptor: that lookup goes through the font daemon, and when it
    /// came back empty (the font database logging `MDB_MAP_FULL`) Core Text
    /// answered with LastResort — a face with no ASCII glyphs, for the
    /// session's whole life. The copy keeps the face and its matrix.
    static func pinningCascadeList(
        _ font: CTFont, size: CGFloat, lead: CJKLead = localeLead, cjk: String? = nil
    ) -> CTFont {
        let isBold = CTFontGetSymbolicTraits(font).contains(.traitBold)
        let attributes = CTFontDescriptorCreateWithAttributes(
            [kCTFontCascadeListAttribute: cascade(lead: lead, bold: isBold, cjk: cjk)] as CFDictionary)
        return CTFontCreateCopyWithAttributes(font, size, nil, attributes)
    }
}

/// How text draws beyond its face: line spacing, fallback, emoji. Carried
/// from the configuration to the renderer and its atlas.
public nonisolated struct TextOptions: Equatable, Sendable {
    public var lineSpacing: CGFloat
    /// Off, a character the primary lacks draws as the missing-glyph box.
    public var fallback: Bool
    /// Emoji draw as text where another face has the scalar in outline.
    public var monochromeEmoji: Bool
    /// The CJK family first in the cascade; nil follows the system language.
    public var cjkFamily: String?

    public init(
        lineSpacing: CGFloat = CellMetrics.defaultLineSpacing, fallback: Bool = true, monochromeEmoji: Bool = false,
        cjkFamily: String? = nil
    ) {
        self.lineSpacing = lineSpacing
        self.fallback = fallback
        self.monochromeEmoji = monochromeEmoji
        self.cjkFamily = cjkFamily
    }
}

/// The configured text, except its size, which a window can zoom alone.
nonisolated struct FontStyle: Equatable, Sendable {
    var family = Configuration.systemFontFamily
    var weight: Configuration.FontWeight = .regular
    var options = TextOptions()

    init() {}

    init(_ configuration: Configuration) {
        family = configuration.fontFamily
        weight = configuration.fontWeight
        options = TextOptions(
            lineSpacing: configuration.lineSpacing, fallback: configuration.fontFallback,
            monochromeEmoji: configuration.emojiRendering == .monochrome,
            cjkFamily: configuration.cjkFontFamily == Configuration.automaticCJKFontFamily
                ? nil : configuration.cjkFontFamily)
    }

    func font(ofSize size: CGFloat) -> CTFont {
        TerminalFont.primary(ofSize: size, family: family, weight: weight, cjk: options.cjkFamily)
    }
}
