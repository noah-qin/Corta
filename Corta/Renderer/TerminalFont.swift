import AppKit
import CoreText

/// The terminal's font stack.
///
/// **Latin / ASCII / code**: System Monospaced, asked for through AppKit so
/// the exact face tracks the OS. **Chinese**: PingFang SC. **Emoji**: Apple
/// Color Emoji. The two fallbacks are a *pinned* cascade list set as
/// `kCTFontCascadeListAttribute` on the font's descriptor, so a scalar the
/// primary lacks resolves deterministically instead of walking whatever
/// cascade the system happens to pick for the current locale.
///
/// One caveat shapes the API: deriving a font through
/// `CTFontCreateCopyWithSymbolicTraits` (the atlas's bold variant) *drops*
/// the cascade-list attribute, while `CTFontCreateCopyWithAttributes` (the
/// renderer's backing-scale resize) keeps it — verified behaviour, not
/// documented. So every derivation that matters re-pins the list rather
/// than trusting inheritance.
nonisolated enum TerminalFont {
    /// The descriptors the cascade resolves through, in order. Point size is
    /// irrelevant on a descriptor; a cascade font instantiates at the
    /// primary's size when a run falls back to it. `CTFontDescriptor` is not
    /// `Sendable`, but this list is immutable after initialisation and the
    /// descriptors are only ever read — hence `nonisolated(unsafe)`.
    private nonisolated(unsafe) static let cascadeList: [CTFontDescriptor] = [
        CTFontDescriptorCreateWithNameAndSize("PingFangSC-Regular" as CFString, 0),
        CTFontDescriptorCreateWithNameAndSize("AppleColorEmoji" as CFString, 0),
    ]

    /// The primary font at `size` points, cascade list already pinned.
    /// `.medium` matches Terminal.app's on-screen stem density at 12pt;
    /// `.regular` rasterises roughly a quarter lighter through the grayscale
    /// Metal atlas and reads soft even when its quads are pixel-aligned.
    ///
    /// - Parameter family: a font family from the settings page (M6.1), or
    ///   `nil` for System Monospaced. A family that is not installed, or that
    ///   `MonospacedFontCatalog` will not vouch for, falls back to the system
    ///   font rather than laying an uneven face out on a grid — the same
    ///   check the settings page filters its list with, applied again here
    ///   because the config file is hand-editable and can name anything.
    static func primary(ofSize size: CGFloat, family: String? = nil) -> CTFont {
        if let family, family != Configuration.systemFontFamily,
            MonospacedFontCatalog.isUsable(family: family),
            let font = NSFont(name: family, size: size) ?? namedFamily(family, size: size)
        {
            return pinningCascadeList(font as CTFont, size: size)
        }
        let system = NSFont.monospacedSystemFont(ofSize: size, weight: .medium) as CTFont
        return pinningCascadeList(system, size: size)
    }

    /// `NSFont(name:)` wants a *face* name ("Menlo-Regular"); the settings
    /// page lists *family* names ("Menlo"). This resolves the latter.
    private static func namedFamily(_ family: String, size: CGFloat) -> NSFont? {
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
        return NSFont(descriptor: descriptor, size: size)
    }

    /// One styled variant of `font` — what the atlas rasterises bold, italic
    /// and bold-italic cells with, alongside whether the bold half had to be
    /// faked.
    ///
    /// Neither style is allowed to silently disappear. A family with no bold
    /// face used to fall back to the regular one, so `SGR 1` content simply
    /// stopped being bold; a family with no italic face had nothing to fall
    /// back *to*, because italics were never rendered at all. Both are now
    /// synthesised when the real face is missing:
    ///
    /// - **Italic** by an oblique shear on the font matrix, which is what a
    ///   text system does for a missing italic and what keeps the advance
    ///   unchanged (a sheared glyph is the same width at the baseline).
    /// - **Bold** by stroking the outline as well as filling it, which the
    ///   atlas does at rasterisation time — hence the flag, since a font
    ///   cannot carry that instruction.
    ///
    /// The trait copy drops the cascade list (see the type comment), so it is
    /// re-pinned here; without this a bold CJK scalar would resolve through
    /// the system cascade instead of PingFang SC.
    static func variant(of font: CTFont, bold: Bool, italic: Bool)
        -> (font: CTFont, syntheticBold: Bool)
    {
        let size = CTFontGetSize(font)
        guard bold || italic else { return (pinningCascadeList(font, size: size), false) }

        var desired: CTFontSymbolicTraits = []
        if bold { desired.insert(.traitBold) }
        if italic { desired.insert(.traitItalic) }
        let derived =
            CTFontCreateCopyWithSymbolicTraits(font, 0, nil, desired, desired) ?? font
        let actual = CTFontGetSymbolicTraits(derived)

        var styled = derived
        // The family has no italic face: shear the regular one. `c` is the
        // usual ~12° oblique (tan 12° ≈ 0.21).
        if italic, !actual.contains(.traitItalic) {
            var matrix = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)
            styled = CTFontCreateCopyWithAttributes(derived, 0, &matrix, nil)
        }
        return (
            pinningCascadeList(styled, size: size),
            bold && !actual.contains(.traitBold)
        )
    }

    /// The bold variant of `font`, kept as the name the atlas and its tests
    /// have always used for the common case.
    static func bold(of font: CTFont) -> CTFont {
        variant(of: font, bold: true, italic: false).font
    }

    /// Returns `font` with the pinned cascade list (re)applied. Idempotent;
    /// safe on fonts that already carry the list.
    static func pinningCascadeList(_ font: CTFont, size: CGFloat) -> CTFont {
        let attributes = [kCTFontCascadeListAttribute: cascadeList] as CFDictionary
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(font), attributes)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }
}
