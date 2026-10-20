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

    /// A hand-edited config can name anything, so the same check runs at the
    /// font's construction site and falls back to System Monospaced.
    @Test func primaryFontRefusesAnUnusableFamily() {
        let fallback = TerminalFont.primary(ofSize: 12, family: "Helvetica")
        let system = TerminalFont.primary(ofSize: 12, family: nil)
        #expect(
            CTFontCopyPostScriptName(fallback) as String
                == CTFontCopyPostScriptName(system) as String)
    }

    /// `NSFont(name:)` also takes a face, which `isUsable` never measured:
    /// a face name is not a family, reported as missing and never drawn.
    @Test func aFaceNameIsNotAFamily() {
        #expect(TerminalFont.resolution(forFamily: "Menlo-Bold") == .missing(requested: "Menlo-Bold"))
        #expect(!MonospacedFontCatalog.isUsable(family: "Menlo-Bold"))
        let system = TerminalFont.primary(ofSize: 12, family: nil)
        #expect(
            CTFontCopyPostScriptName(TerminalFont.primary(ofSize: 12, family: "Menlo-Bold")) as String
                == CTFontCopyPostScriptName(system) as String)
    }

    /// The list comes from Core Text, off the main thread, without the
    /// private "." system families; a refresh gives the same verdicts.
    @Test func theCatalogListsPublicFamiliesAndSurvivesARefresh() {
        let names = MonospacedFontCatalog.families()
        #expect(names.contains("Menlo"))
        #expect(!names.contains { $0.hasPrefix(".") })
        MonospacedFontCatalog.refresh()
        #expect(MonospacedFontCatalog.isUsable(family: "Menlo"))
        #expect(!MonospacedFontCatalog.isUsable(family: "Helvetica"))
        #expect(MonospacedFontCatalog.families() == names)
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
        let atlas = try GlyphAtlas(
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
    /// a scalar the primary font does not map comes back flagged rather
    /// than `nil`, so the renderer can draw a placeholder box instead of
    /// leaving a hole in the output.
    @Test func theFastPathReportsAnUnmappedScalarAsMissing() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let atlas = try GlyphAtlas(
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
        let atlas = try GlyphAtlas(
            device: device, font: CTFontCreateWithName("Menlo" as CFString, 14, nil))
        let info = try #require(atlas.glyph(shaping: 0x00A0, style: .regular))  // NBSP
        #expect(!info.isMissing)
    }

    // MARK: - Fallback symbols

    /// System Monospaced, as the app builds it, with the pinned cascade.
    private static func systemAtlas() throws -> GlyphAtlas? {
        guard let device = makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return nil
        }
        return try GlyphAtlas(device: device, font: TerminalFont.primary(ofSize: 24))
    }

    private static func inkMidY(_ runs: [GlyphAtlas.ShapedRun]) -> CGFloat {
        runs.reduce(CGRect.null) { bounds, run in
            var glyphs = run.glyphs
            var rects = [CGRect](repeating: .zero, count: glyphs.count)
            CTFontGetBoundingRectsForGlyphs(run.font, .horizontal, &glyphs, &rects, glyphs.count)
            return zip(rects, run.positions).reduce(bounds) { $0.union($1.0.offsetBy(dx: $1.1.x, dy: $1.1.y)) }
        }.midY
    }

    /// Core Text answered SF Mono Medium's missing `❯` with Menlo Bold; the
    /// prompt's chevron drew heavier than the `~` beside it.
    @Test func aFallbackSymbolIsNoBolderThanItsText() throws {
        guard let atlas = try Self.systemAtlas() else { return }
        let regular = try #require(atlas.shape("❯", style: .regular).runs.first)
        #expect(!CTFontGetSymbolicTraits(regular.font).contains(.traitBold))
        #expect(!regular.glyphs.contains(0))
        // Bold text keeps a bold fallback.
        let bold = try #require(atlas.shape("❯", style: .bold).runs.first)
        #expect(CTFontGetSymbolicTraits(bold.font).contains(.traitBold))
    }

    /// A fallback symbol sits where SF Mono centres its own: half its cap
    /// height. Menlo's `❯` was 0.07 em below that.
    @Test func aFallbackSymbolIsCentredOnThePrimary() throws {
        guard let atlas = try Self.systemAtlas() else { return }
        let capMid = CTFontGetCapHeight(atlas.fonts[0]) / 2
        for symbol in ["❯", "◆", "⇒"] {
            let runs = atlas.shape(symbol, style: .regular).runs
            #expect(abs(Self.inkMidY(runs) - capMid) < 0.5, "\(symbol)")
        }
    }

    /// Braille dots and the primary's own symbols stay where their font put
    /// them: a graph needs its dots in place.
    @Test func brailleAndThePrimarysOwnGlyphsAreNotMoved() throws {
        guard let atlas = try Self.systemAtlas() else { return }
        for text in ["⠁", "→", "中"] {
            let runs = atlas.shape(text, style: .regular).runs
            #expect(runs.allSatisfy { $0.positions.allSatisfy { $0.y == 0 } }, "\(text)")
        }
    }

    /// Pieces whose height is their meaning keep it: ncurses' scan lines,
    /// bracket pieces that join across rows, corner triangles.
    @Test func positionalSymbolsAreNotCentred() {
        for text in ["⎺", "⎽", "⎛", "⌠", "◢", "◥", "◜", "◸"] {
            #expect(!GlyphAtlas.isStandaloneSymbol(Array(text.utf16)), "\(text)")
        }
        for text in ["❯", "◆", "⇒", "●", "⏎"] {
            #expect(GlyphAtlas.isStandaloneSymbol(Array(text.utf16)), "\(text)")
        }
    }

    /// Unbolding a fallback keeps its slant: a fallback run under a sheared
    /// family carries the shear, and `❯` must not stand upright among
    /// sheared letters.
    @Test func anUnboldedFallbackKeepsItsSlant() {
        var shear = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)
        let bold = CTFontCreateWithName("Menlo-Bold" as CFString, 24, &shear)
        let lighter = GlyphAtlas.lighter(than: bold)
        #expect(CTFontCopyPostScriptName(lighter) as String == "Menlo-Regular")
        #expect(CTFontGetMatrix(lighter).c == 0.21)
        let boldItalic = CTFontCreateWithName("Menlo-BoldItalic" as CFString, 24, nil)
        #expect(CTFontCopyPostScriptName(GlyphAtlas.lighter(than: boldItalic)) as String == "Menlo-Italic")
    }

    /// CJK in bold text is bold: the cascade under a real bold face is
    /// PingFang Semibold, not the Regular that drew 粗体 light.
    @Test func boldCJKUsesABoldFallback() throws {
        guard let atlas = try Self.systemAtlas() else { return }
        let regular = try #require(atlas.shape("粗", style: .regular).runs.first)
        let bold = try #require(atlas.shape("粗", style: .bold).runs.first)
        #expect(CTFontCopyPostScriptName(regular.font) as String == "PingFangSC-Regular")
        #expect(CTFontCopyPostScriptName(bold.font) as String == "PingFangSC-Semibold")
    }
}
