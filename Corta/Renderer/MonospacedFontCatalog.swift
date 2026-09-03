import AppKit
import CoreText
import Synchronization

/// Which installed font families a grid terminal can actually lay out.
///
/// `NSFont.isFixedPitch` is not that answer. It is a flag on one face, and
/// the renderer's real assumption is stronger: *every* glyph Corta draws —
/// in the regular face and in the bold, italic and bold-italic faces derived
/// from it — advances by exactly one cell width. Families that claim
/// fixed-pitch and break that assumption are common, and each break has a
/// visible cost:
///
/// - A family whose bold face is wider than its regular one paints bold text
///   into the neighbouring column.
/// - A family that is monospaced for letters but not for digits or box-drawing
///   characters makes every TUI border and progress bar ragged.
/// - A bitmap-only or colour face has no outline to rasterise at an arbitrary
///   size: it comes out blurry, or (through the colour path) blank.
///
/// So a family is offered only if it passes all three checks, measured on the
/// faces Corta will really use. The list is asked of AppKit rather than
/// hardcoded — a font the user installs must show up — but it is *verified*
/// rather than trusted.
///
/// Enumerating and measuring a few hundred families takes long enough to be
/// worth doing once, so the result is cached; `refresh()` drops the cache.
nonisolated enum MonospacedFontCatalog {
    /// The size everything is measured at. Advances scale linearly, so the
    /// choice only affects the tolerance's units.
    private static let measurementSize: CGFloat = 12
    /// Two advances count as equal within this many points at
    /// `measurementSize`. Hinting and rounding move a true monospace font's
    /// advances by far less; a font that is only "mostly" fixed misses by
    /// tenths of a point or more.
    private static let tolerance: CGFloat = 0.01

    /// The ASCII printable range. Every character a shell prompt, a TUI
    /// border and a column of numbers is made of lives here, which is exactly
    /// the set whose advances have to agree.
    private static let measuredCharacters: [UniChar] = (0x20...0x7E).map(UniChar.init)

    /// Behind a mutex, not a bare `static var`: the settings page reads this
    /// on the main thread and the tests read it from several at once, and an
    /// unsynchronised cache of a heap value is a data race in both.
    private static let cache = Mutex<[String]?>(nil)

    /// Every installed family Corta can render on a grid, sorted.
    static func families() -> [String] {
        cache.withLock { cached in
            if let cached { return cached }
            let manager = NSFontManager.shared
            let families = manager.availableFontFamilies.filter(isUsable(family:)).sorted()
            cached = families
            return families
        }
    }

    /// Drops the cache — for a test, or after the set of installed fonts
    /// could have changed.
    static func refresh() {
        cache.withLock { $0 = nil }
    }

    /// Whether `family` renders correctly on the grid: an outline face whose
    /// ASCII advances are uniform, and whose bold, italic and bold-italic
    /// derivations keep that same advance.
    ///
    /// A family with no real italic face passes: the derivation falls back to
    /// the regular face, which by definition still matches, and
    /// `TerminalFont` synthesises the slant. The check is about faces that
    /// exist and *disagree*.
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

    /// The single advance every ASCII printable shares in `font`, or `nil`
    /// when the font is not an outline font, does not cover the range, or
    /// advances unevenly across it.
    static func uniformAdvance(of font: CTFont) -> CGFloat? {
        guard hasOutlines(font) else { return nil }
        var characters = measuredCharacters
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        // Returns false when *any* character is unmapped. A terminal font
        // that cannot draw part of ASCII is not a terminal font.
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
        else { return nil }
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advances, glyphs.count)
        guard let first = advances.first?.width, first > 0 else { return nil }
        for advance in advances where abs(advance.width - first) > tolerance { return nil }
        return first
    }

    /// Whether the font has scalable outlines rather than colour or bitmap
    /// strikes. A bitmap face has no outline table, and drawing one at a size
    /// it was not cut for is what makes the text look smeared; a colour face
    /// never reaches the coverage atlas at all.
    private static func hasOutlines(_ font: CTFont) -> Bool {
        guard !CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) else { return false }
        // TrueType outlines live in `glyf`; PostScript outlines in `CFF ` or
        // its version 2. A face carrying none of the three is bitmap-only.
        let outlineTables: [CTFontTableTag] = [
            CTFontTableTag(kCTFontTableGlyf),
            CTFontTableTag(kCTFontTableCFF),
            0x4346_4632,  // 'CFF2'
        ]
        return outlineTables.contains { CTFontCopyTable(font, $0, []) != nil }
    }
}
