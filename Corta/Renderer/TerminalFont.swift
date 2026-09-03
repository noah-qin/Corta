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
    ///   `nil` for System Monospaced. A family that is not installed, or
    ///   whose faces are not fixed-pitch, falls back to the system font
    ///   rather than laying a proportional face out on a grid.
    static func primary(ofSize size: CGFloat, family: String? = nil) -> CTFont {
        if let family, family != Configuration.systemFontFamily,
            let font = NSFont(name: family, size: size) ?? namedFamily(family, size: size),
            font.isFixedPitch
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

    /// The bold variant of `font` — what the atlas rasterises bold cells
    /// with. The trait copy drops the cascade list (see the type comment),
    /// so it is re-pinned here; without this a bold CJK scalar would resolve
    /// through the system cascade instead of PingFang SC.
    static func bold(of font: CTFont) -> CTFont {
        let derived = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitBold, .traitBold) ?? font
        return pinningCascadeList(derived, size: CTFontGetSize(font))
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
