import Testing

@testable import CortaTerminal

/// M2.1 — the character width table (`docs/ROADMAP.md`, `CONFORMANCE.md` §1.1).
///
/// Every expected width below is derived from the Unicode 17.0.0 data files
/// the table was generated from; the comment on each case cites the file and
/// the line or record that settles it:
///
///   - `EastAsianWidth-17.0.0.txt`   — Wide/Fullwidth -> 2
///   - `UnicodeData-17.0.0.txt`      — Mn/Me/Cc/Cf -> 0
///   - `emoji-data.txt` 17.0.0       — Emoji_Presentation=Yes -> 2
@Suite("Character width")
struct CharacterWidthTests {
    /// (scalar, expected width) — table-driven over checked-in scalars.
    static let cases: [(UInt32, Int)] = [
        // ASCII — plain letters and space are 1 (default; no rule matches).
        (0x0041, 1),  // 'A' — UnicodeData: LATIN CAPITAL LETTER A;Lu
        (0x007A, 1),  // 'z'
        (0x0020, 1),  // space — EastAsianWidth: 0020;Na

        // Controls — Cc -> 0 (UnicodeData: 0000;<control>;Cc, 007F;<control>;Cc).
        (0x0000, 0),  // NUL
        (0x0007, 0),  // BEL
        (0x001B, 0),  // ESC
        (0x007F, 0),  // DEL
        (0x0080, 0),  // C1 control

        // Zero-width characters — Cf -> 0.
        (0x200B, 0),  // ZWSP — UnicodeData: ZERO WIDTH SPACE;Cf
        (0x200D, 0),  // ZWJ  — UnicodeData: ZERO WIDTH JOINER;Cf
        (0x00AD, 0),  // soft hyphen — UnicodeData: SOFT HYPHEN;Cf
        (0xFEFF, 0),  // BOM / zero-width no-break space — Cf

        // Combining marks — Mn/Me -> 0.
        (0x0301, 0),  // UnicodeData: COMBINING ACUTE ACCENT;Mn
        (0x036F, 0),  // end of the 0300..036F combining block
        (0x20E0, 0),  // UnicodeData: COMBINING ENCLOSING CIRCLE BACKSLASH;Me

        // Variation selectors — Mn -> 0 (even though EAW marks them Ambiguous).
        (0xFE0F, 0),  // VS16 — UnicodeData: VARIATION SELECTOR-16;Mn
        (0xE01EF, 0), // VS256 — UnicodeData: VARIATION SELECTOR-256;Mn

        // Zero-width beats wide: U+3099 is Mn *and* EAW=W
        // (EastAsianWidth: 3099..309A;W) — combining wins, width 0.
        (0x3099, 0),

        // CJK ideographs — EAW Wide -> 2 (EastAsianWidth: 4E00..9FFF;W).
        (0x4E2D, 2),  // 中
        (0x9FFF, 2),  // block end
        (0x20000, 2), // CJK Extension B — EastAsianWidth: 20000..2FFFD;W

        // Hangul syllables — EAW Wide -> 2 (EastAsianWidth: AC00..D7A3;W).
        (0xAC00, 2),  // 가
        (0xD7A3, 2),  // 힣
        // Hangul choseong is Wide too (EastAsianWidth: 1100..115F;W)…
        (0x1100, 2),
        // …but conjoining jungseong/jongseong are Lo, EAW=N -> 1 under the
        // locked rules (UnicodeData: 1161;HANGUL JUNGSEONG A;Lo).
        (0x1161, 1),

        // Fullwidth forms — EAW Fullwidth -> 2 (EastAsianWidth: FF21..FF3A;F).
        (0xFF21, 2),  // Ａ FULLWIDTH LATIN CAPITAL LETTER A
        (0xFF01, 2),  // ！ FULLWIDTH EXCLAMATION MARK — EastAsianWidth: FF01..FF03;F

        // Halfwidth katakana — EAW Halfwidth -> 1 (EastAsianWidth: FF61..FFDC;H).
        (0xFF76, 1),  // ｶ HALFWIDTH KATAKANA LETTER KA

        // Ambiguous — EAW Ambiguous resolves to 1 (narrow) in a terminal.
        (0x00A1, 1),  // ¡ — EastAsianWidth: 00A1;A
        (0x03B1, 1),  // α — EastAsianWidth: 0391..03A1/03A3..03E1;A

        // Emoji with default emoji presentation -> 2
        // (emoji-data: 1F600;Emoji_Presentation; also EAW W: 1F600..1F64F;W).
        (0x1F600, 2), // 😀 grinning face
        (0x1F64F, 2), // range end; the next block downgrades:
        (0x1F650, 1), // EAW N, no Emoji_Presentation -> 1
        // Emoji presentation without EAW=W — emoji-data alone drives the 2
        // (emoji-data: 1F1E6..1F1FF;Emoji_Presentation; EAW is N).
        (0x1F1FA, 2), // regional indicator symbol U
        // Emoji=Yes but Emoji_Presentation=No — stays 1 until VS16 asks for
        // emoji presentation (emoji-data: 2764;Emoji, no Emoji_Presentation;
        // EastAsianWidth: 2764;N).
        (0x2764, 1),  // ❤ heavy black heart

        // Unassigned scalars are width 1 — the grid must not make
        // not-yet-assigned output vanish.
        (0x0378, 1),  // unassigned in the Greek block
        (0x10FFFF, 1), // noncharacter, unassigned
    ]

    @Test("checked-in scalars have the expected width", arguments: cases)
    func widthOfCheckedInScalars(scalar: UInt32, expected: Int) {
        #expect(displayWidth(of: Unicode.Scalar(scalar)!) == expected)
    }

    @Test("the width is never outside 0...2")
    func widthsAreBounded() {
        // Sweep a spread of the codespace, including every range boundary.
        var samples: [UInt32] = [0, 0x10FFFF]
        for range in characterWidthRanges {
            samples.append(range.lower)
            samples.append(range.upper)
        }
        for value in samples {
            guard let scalar = Unicode.Scalar(value) else { continue }
            #expect((0...2).contains(displayWidth(of: scalar)))
        }
    }

    /// The binary search depends on these invariants; they are properties of
    /// the generated data, so they are checked here rather than by eye.
    @Test("the range table is sorted, non-overlapping, and only 0 or 2")
    func rangeTableIsWellFormed() {
        var previousUpper: UInt32? = nil
        for range in characterWidthRanges {
            #expect(range.lower <= range.upper)
            #expect(range.width == 0 || range.width == 2)
            if let previousUpper {
                #expect(previousUpper < range.lower)
            }
            previousUpper = range.upper
        }
    }
}
