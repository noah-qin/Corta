import AppKit
import CoreText
import Metal
import Testing

@testable import Corta

/// U18: what the font pipeline offers beyond the shipped face — ligatures,
/// and a third-party family named from the config file.
///
/// **Ligatures are not supported, and these tests pin that as a property
/// rather than an omission.** Corta rasterises one glyph per cell: ASCII
/// through `CTFontGetGlyphsForCharacters` with no shaping at all, everything
/// else through a `CTLine` shaped over a *single* scalar or one grapheme
/// cluster. A ligature is a substitution across adjacent, independent cells,
/// which no key in that cache can express — so the substitution never has an
/// opportunity to happen, even in a face that carries it. Supporting them
/// means shaping runs across cells and dealing with the grid consequences
/// `DESIGN.md` §7.3 lists (a ligature spanning cells, a cursor inside one
/// having to break it), which is a renderer change, not a font option.
///
/// `.serialized`: the atlas cases build a `GlyphAtlas`, which is
/// single-threaded by design — see that type's comment.
@Suite(.serialized) struct FontOptionsTests {
    private static func makeDevice() -> MTLDevice? { MTLCreateSystemDefaultDevice() }

    /// Programming faces people actually ask for, then the monospaced
    /// families macOS itself ships that are *not* the default, so the
    /// end-to-end case has something to run on any machine.
    private static let thirdPartyCandidates = [
        "Fira Code", "JetBrains Mono", "Cascadia Code", "IBM Plex Mono",
        "Source Code Pro", "Hack", "Iosevka", "Andale Mono", "PT Mono",
    ]

    private static func installedCandidate() -> String? {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return thirdPartyCandidates.first { installed.contains($0) }
    }

    /// How many glyphs Core Text produces for `text` in `font` — fewer than
    /// the characters means a substitution (a ligature) fired.
    private static func shapedGlyphCount(_ text: String, in font: CTFont) -> Int {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        let runs = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []
        return runs.reduce(0) { $0 + CTRunGetGlyphCount($1) }
    }

    // MARK: - Ligatures

    /// One glyph per cell, and — the reason it can be nothing else — the
    /// ASCII path does not shape at all, so there is no run for a `liga`
    /// substitution to apply to. The probe records whether the shipped face
    /// would ligate "fi" if it were shaped: on macOS 26 no installed
    /// monospaced family does (checked across every family the catalog
    /// offers), so ligature support cannot be demonstrated by rendering
    /// here — it is ruled out structurally instead.
    @Test func theASCIIPathNeverShapesSoNoLigatureCanApply() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let primary = TerminalFont.primary(ofSize: 24, family: nil)
        let ligates = Self.shapedGlyphCount("fi", in: primary) < 2
        let atlas = GlyphAtlas(device: device, font: primary)
        let f = try #require(atlas.glyph(forASCII: UInt32(UInt8(ascii: "f")), style: .regular))
        let i = try #require(atlas.glyph(forASCII: UInt32(UInt8(ascii: "i")), style: .regular))
        #expect(!f.isMissing && !i.isMissing)
        #expect(f.uvRect != i.uvRect, "'f' and 'i' shared an atlas entry (ligated?)")
        #expect(atlas.shapingHits == 0, "ligation would need shaping; the ASCII path has none")
        if ligates {
            print("note: the shipped face now ligates 'fi' when shaped; the grid still does not")
        }
    }

    /// The programmer's ligature — "=>" — is not applied either, and here no
    /// installed face would apply it anyway: the point is that each of the
    /// two scalars is an independent, cell-wide atlas entry, which is what
    /// makes column alignment hold.
    @Test func operatorSequencesStayOneScalarPerCell() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let font = TerminalFont.primary(ofSize: 24, family: nil)
        let atlas = GlyphAtlas(device: device, font: font)
        let equals = try #require(atlas.glyph(forASCII: UInt32(UInt8(ascii: "=")), style: .regular))
        let greater = try #require(atlas.glyph(forASCII: UInt32(UInt8(ascii: ">")), style: .regular))
        #expect(equals.uvRect != greater.uvRect)
        // The cell is sized off the font's uniform advance, not off what a
        // shaped run would measure, so a ligature could not fit it even if
        // one were produced.
        let metrics = CellMetrics(font: font)
        var glyph = CGGlyph(0)
        var character = UniChar(UInt8(ascii: "="))
        #expect(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        #expect(abs(metrics.cellWidth - advance.width) < 1, "cell tracks the single-glyph advance")
    }

    /// A ligature-capable programming font, if the machine has one, must be
    /// *offered* — its ASCII advances are uniform, so nothing about carrying
    /// ligatures disqualifies it — while still rendering one glyph per cell.
    /// Skipped, not failed, where none is installed.
    @Test func aLigatureCapableProgrammingFontIsStillOfferedAndStillGridded() throws {
        let ligatureFonts = ["Fira Code", "JetBrains Mono", "Cascadia Code", "Iosevka"]
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        guard let family = ligatureFonts.first(where: { installed.contains($0) }) else {
            print("note: no ligature-capable programming font installed; nothing to check")
            return
        }
        #expect(MonospacedFontCatalog.isUsable(family: family))
        guard let device = Self.makeDevice() else { return }
        let font = TerminalFont.primary(ofSize: 24, family: family)
        let atlas = GlyphAtlas(device: device, font: font)
        let equals = try #require(atlas.glyph(forASCII: UInt32(UInt8(ascii: "=")), style: .regular))
        let greater = try #require(atlas.glyph(forASCII: UInt32(UInt8(ascii: ">")), style: .regular))
        #expect(equals.uvRect != greater.uvRect, "\(family) ligated across two cells")
    }

    // MARK: - A third-party family, config file to font

    /// `font-family` naming an installed, verified family has to survive
    /// parsing *and* resolve to a face of that family — not quietly fall back
    /// to System Monospaced, which is what an unusable family does.
    @Test func aThirdPartyFamilyResolvesFromTheConfigFile() throws {
        let family = try #require(
            Self.installedCandidate(), "no candidate monospaced family installed")
        #expect(MonospacedFontCatalog.isUsable(family: family), "\(family) was not offered")

        let parsed = Configuration.parse("font-family = \(family)\nfont-size = 13\n")
        #expect(parsed.configuration.fontFamily == family)
        #expect(parsed.unknown.isEmpty)

        let font = TerminalFont.primary(
            ofSize: parsed.configuration.fontSize, family: parsed.configuration.fontFamily)
        #expect(CTFontCopyFamilyName(font) as String == family)
        let system = TerminalFont.primary(ofSize: parsed.configuration.fontSize, family: nil)
        #expect(
            CTFontCopyPostScriptName(font) as String != CTFontCopyPostScriptName(system) as String,
            "\(family) resolved to the system face instead of itself")
        // The catalog is the gate the settings page lists from, so a family
        // the config can name has to appear there too.
        #expect(MonospacedFontCatalog.families().contains(family))
    }
}
