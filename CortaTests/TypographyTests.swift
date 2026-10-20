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
import CortaTerminal
import Metal
import Testing

@testable import Corta

/// The typography preferences: weight, line spacing, fallback, emoji and
/// ambiguous width, as the configuration file reads them.
struct TypographyConfigurationTests {
    @Test("the defaults: 13 pt Regular, 1.18 line spacing, fallback on, colour emoji, narrow")
    func defaults() {
        let configuration = Configuration()
        #expect(configuration.fontSize == 13)
        #expect(configuration.fontWeight == .regular)
        #expect(configuration.lineSpacing == 1.18)
        #expect(configuration.fontFallback)
        #expect(configuration.emojiRendering == .color)
        #expect(configuration.ambiguousWidth == .narrow)
    }

    @Test("each key reads, and a bad value keeps the default")
    func keysRead() {
        let (parsed, unknown) = Configuration.parse("""
            font-weight = light
            font-fallback = false
            emoji-rendering = monochrome
            ambiguous-width = wide
            """)
        #expect(unknown.isEmpty)
        #expect(parsed.fontWeight == .light)
        #expect(!parsed.fontFallback)
        #expect(parsed.emojiRendering == .monochrome)
        #expect(parsed.ambiguousWidth == .wide)
        #expect(Configuration.parse("font-weight = heavy").configuration.fontWeight == .regular)
    }

    /// 1.0–1.4 on a 0.02 grid, written back as a person would write it.
    @Test("line spacing is clamped and snapped to 0.02")
    func lineSpacingSnaps() {
        #expect(Configuration.parse("line-spacing = 1.179").configuration.lineSpacing == 1.18)
        #expect(Configuration.parse("line-spacing = 1.205").configuration.lineSpacing == 1.2)
        #expect(Configuration.parse("line-spacing = 1.3").configuration.lineSpacing == 1.3)
        #expect(Configuration.parse("line-spacing = 0.5").configuration.lineSpacing == 1.0)
        #expect(Configuration.parse("line-spacing = 9").configuration.lineSpacing == 1.4)
        var configuration = Configuration()
        configuration.lineSpacing = Configuration.snappedLineSpacing(1.2)
        #expect(configuration.serialized().contains("line-spacing = 1.2\n"))
    }

    @Test("the user's language picks the CJK face for Han")
    func languagePicksTheLead() {
        typealias Lead = TerminalFont.CJKLead
        #expect(Lead.forLanguages(["zh-Hans-CN"]) == .simplifiedChinese)
        #expect(Lead.forLanguages(["zh-Hant-TW"]) == .traditionalChinese)
        #expect(Lead.forLanguages(["zh-HK"]) == .traditionalChinese)
        #expect(Lead.forLanguages(["ja-JP"]) == .japanese)
        #expect(Lead.forLanguages(["ko-KR"]) == .korean)
        #expect(Lead.forLanguages(["en-US", "ja-JP"]) == .simplifiedChinese)
        #expect(Lead.forLanguages([]) == .simplifiedChinese)
    }

    /// The order the cascade lists: the lead, then the other scripts, then
    /// emoji.
    @Test("the cascade leads with the language's face")
    func cascadeOrder() {
        let names = TerminalFont.cascade(lead: .japanese, bold: false).compactMap {
            CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String
        }
        #expect(names == [
            "HiraginoSans-W3", "PingFangSC-Regular", "PingFangTC-Regular", "AppleSDGothicNeo-Regular",
            "AppleColorEmoji",
        ])
        let bold = TerminalFont.cascade(lead: .simplifiedChinese, bold: true).compactMap {
            CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String
        }
        #expect(bold.first == "PingFangSC-Semibold")
    }

    /// A weight the family lacks is its Regular, never a Bold standing in.
    @Test("the weight picks the face, or Regular where there is none")
    func weightPicksTheFace() {
        let light = TerminalFont.primary(ofSize: 13, weight: .light)
        #expect((CTFontCopyPostScriptName(light) as String).hasSuffix("Light"))
        let medium = TerminalFont.primary(ofSize: 13, weight: .medium)
        #expect((CTFontCopyPostScriptName(medium) as String).hasSuffix("Medium"))
        let menlo = TerminalFont.primary(ofSize: 13, family: "Menlo", weight: .medium)
        #expect(CTFontCopyPostScriptName(menlo) as String == "Menlo-Regular")
    }
}

/// What the atlas draws a character with, and where, under those
/// preferences. `.serialized`: each builds a `GlyphAtlas`, single-threaded
/// by design.
@Suite(.serialized, .metalSerialized, .enabled(if: MetalRenderTarget.supportsMetal4, MetalRenderTarget.metal4Requirement))
struct TypographyAtlasTests {
    private static func atlas(_ options: TextOptions = TextOptions()) throws -> GlyphAtlas {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return try GlyphAtlas(device: device, font: TerminalFont.primary(ofSize: 26), options: options)
    }

    private static func name(_ run: GlyphAtlas.ShapedRun) -> String {
        CTFontCopyPostScriptName(run.font) as String
    }

    /// Kana and Hangul take their own script's face whatever the language.
    @Test("kana draws in Hiragino Sans, Hangul in Apple SD Gothic Neo")
    func scriptsTakeTheirOwnFace() throws {
        let atlas = try Self.atlas()
        #expect(try Self.name(#require(atlas.shape("か", style: .regular).runs.first)) == "HiraginoSans-W3")
        #expect(try Self.name(#require(atlas.shape("한", style: .regular).runs.first)) == "AppleSDGothicNeo-Regular")
        #expect(try Self.name(#require(atlas.shape("한", style: .bold).runs.first)) == "AppleSDGothicNeo-SemiBold")
    }

    /// Han follows the language's lead face.
    @Test("Han draws in the language's face")
    func hanFollowsTheLanguage() throws {
        let atlas = try Self.atlas()
        let expected = TerminalFont.localeLead.faces.regular
        #expect(try Self.name(#require(atlas.shape("中", style: .regular).runs.first)) == expected)
    }

    /// `font-fallback = false`: no other face, and a box rather than a blank.
    @Test("with fallback off, a character the primary lacks is missing")
    func fallbackOff() throws {
        let atlas = try Self.atlas(TextOptions(fallback: false))
        let shaped = atlas.shape("中", style: .regular)
        #expect(shaped.runs.isEmpty)
        #expect(shaped.sawNotdef)
        // The primary's own characters are unaffected.
        #expect(!atlas.shape("é", style: .regular).runs.isEmpty)
    }

    @Test("monochrome emoji draw as an outline glyph where a face has one")
    func monochromeEmoji() throws {
        let colour = try #require(Self.atlas().shape("☀️", style: .regular).runs.first)
        #expect(colour.isColor)
        let mono = try #require(Self.atlas(TextOptions(monochromeEmoji: true)).shape("☀️", style: .regular).runs.first)
        #expect(!mono.isColor)
        #expect(!CTFontGetSymbolicTraits(mono.font).contains(.traitColorGlyphs))
        // An emoji no text face has keeps its colour: "where possible".
        let rocket = try #require(Self.atlas(TextOptions(monochromeEmoji: true)).shape("🚀", style: .regular).runs.first)
        #expect(rocket.isColor)
    }

    /// With fallback off, a cluster the primary draws only part of is the
    /// missing-glyph box, not the part: a base letter with a mark only a
    /// fallback has.
    @Test("with fallback off, a part-drawable cluster is the missing box")
    func partialClusterWithoutFallback() throws {
        let shaped = try Self.atlas(TextOptions(fallback: false)).shape("a\u{3099}", style: .regular)
        #expect(shaped.runs.isEmpty)
        #expect(shaped.sawNotdef)
        #expect(try !Self.atlas().shape("a\u{3099}", style: .regular).runs.isEmpty)
    }
}
