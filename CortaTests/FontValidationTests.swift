import AppKit
import CoreText
import Metal
import Testing

@testable import Corta

/// The font-family filter and the three rendering fallbacks that stop a
/// badly-behaved family from being a silent defect: the cell clamp, the
/// missing-glyph box, and synthetic bold/italic.
///
/// `.serialized`: the atlas cases build a `GlyphAtlas`, which is
/// single-threaded by design — see that type's comment.
@Suite(.serialized) struct FontValidationTests {
    private static func makeDevice() -> MTLDevice? { MTLCreateSystemDefaultDevice() }

    // MARK: - The catalog

    @Test func acceptsAKnownGoodTerminalFamily() {
        #expect(MonospacedFontCatalog.isUsable(family: "Menlo"))
    }

    @Test func rejectsAProportionalFamily() {
        #expect(!MonospacedFontCatalog.isUsable(family: "Helvetica"))
    }

    /// The failure the old `isFixedPitch` check let through: a colour bitmap
    /// face has no outline to rasterise at an arbitrary size.
    @Test func rejectsAColorBitmapFamily() {
        #expect(!MonospacedFontCatalog.isUsable(family: "Apple Color Emoji"))
    }

    @Test func rejectsAFamilyThatDoesNotExist() {
        #expect(!MonospacedFontCatalog.isUsable(family: "No Such Family At All"))
    }

    /// Uniformity is measured across the whole ASCII printable range, not off
    /// one representative character: a family that is monospaced for letters
    /// and not for digits makes every TUI border ragged.
    @Test func uniformAdvanceSpansTheASCIIPrintableRange() {
        let menlo = CTFontCreateWithName("Menlo" as CFString, 12, nil)
        let helvetica = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        #expect(MonospacedFontCatalog.uniformAdvance(of: menlo) != nil)
        #expect(MonospacedFontCatalog.uniformAdvance(of: helvetica) == nil)
    }

    @Test func everyOfferedFamilyPassesItsOwnCheck() {
        let families = MonospacedFontCatalog.families()
        #expect(!families.isEmpty)
        for family in families {
            #expect(MonospacedFontCatalog.isUsable(family: family), "\(family) was offered")
        }
    }

    /// A hand-edited config can name anything, so the same check runs at the
    /// font's construction site and falls back to System Monospaced.
    @Test func primaryFontRefusesAnUnusableFamily() {
        let fallback = TerminalFont.primary(ofSize: 12, family: "Helvetica")
        let system = TerminalFont.primary(ofSize: 12, family: nil)
        #expect(
            CTFontCopyPostScriptName(fallback) as String
                == CTFontCopyPostScriptName(system) as String)
    }

    // MARK: - Styles

    /// A family with real italics must use them; the four styles must be four
    /// distinct faces, or `SGR 3` renders as upright text.
    @Test func italicResolvesToTheRealFaceWhenTheFamilyHasOne() {
        let base = CTFontCreateWithName("Menlo" as CFString, 12, nil)
        let italic = TerminalFont.variant(of: base, bold: false, italic: true)
        #expect(CTFontGetSymbolicTraits(italic.font).contains(.traitItalic))
        #expect(!italic.syntheticBold)
        #expect(
            CTFontCopyPostScriptName(italic.font) as String
                != CTFontCopyPostScriptName(base) as String)
    }

    /// And a family without them must still slant: the shear leaves the
    /// advance alone, so the grid is unaffected.
    @Test func italicIsSynthesisedWhenTheFamilyHasNoItalicFace() {
        // A family whose italic derivation cannot succeed still has to come
        // back sheared rather than upright.
        let base = CTFontCreateWithName("Courier" as CFString, 12, nil)
        let italic = TerminalFont.variant(of: base, bold: false, italic: true).font
        let hasRealItalic = CTFontGetSymbolicTraits(italic).contains(.traitItalic)
        let matrix = CTFontGetMatrix(italic)
        #expect(hasRealItalic || matrix.c != 0)
    }

    @Test func boldResolvesToTheRealFaceWithoutSynthesis() {
        let base = CTFontCreateWithName("Menlo" as CFString, 12, nil)
        let bold = TerminalFont.variant(of: base, bold: true, italic: false)
        #expect(CTFontGetSymbolicTraits(bold.font).contains(.traitBold))
        #expect(!bold.syntheticBold)
    }

    @Test func theFourStylesAreCachedSeparately() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let atlas = GlyphAtlas(
            device: device, font: CTFontCreateWithName("Menlo" as CFString, 24, nil))
        let a = UInt32(Character("a").asciiValue!)
        var seen: Set<[Float]> = []
        for style in [GlyphAtlas.Style.regular, .bold, .italic, .boldItalic] {
            let info = try #require(atlas.glyph(forASCII: a, style: style))
            seen.insert([info.uvRect.x, info.uvRect.y, info.size.x, info.size.y])
        }
        // Four styles, four distinct atlas entries — a shared entry would mean
        // one of the renditions is silently drawing another's glyph.
        #expect(seen.count == 4)
    }

    // MARK: - Missing glyphs

    /// The fast path does not shape, so it has no cascade to fall back on:
    /// a scalar the primary font does not map used to come back `nil` and
    /// draw nothing at all. It now comes back flagged, so the renderer can
    /// draw a placeholder box instead of leaving a hole in the output.
    @Test func theFastPathReportsAnUnmappedScalarAsMissing() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let atlas = GlyphAtlas(
            device: device, font: CTFontCreateWithName("Menlo" as CFString, 14, nil))
        // Menlo has no CJK ideograph, and the fast path never consults the
        // cascade list that would find one.
        let info = try #require(atlas.glyph(forASCII: 0x4E2D, style: .regular))
        #expect(info.isMissing)
        #expect(info.size == .zero)
        #expect(atlas.shapingHits == 0)
    }

    /// A space has no ink and is *not* missing — drawing a box for every
    /// blank cell would be worse than the bug this fixes.
    @Test func aBlankIsNotReportedAsMissing() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let atlas = GlyphAtlas(
            device: device, font: CTFontCreateWithName("Menlo" as CFString, 14, nil))
        let info = try #require(atlas.glyph(shaping: 0x00A0, style: .regular))  // NBSP
        #expect(!info.isMissing)
    }
}
