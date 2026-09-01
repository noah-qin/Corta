import Testing

@testable import CortaTerminal

/// M1.6 — the golden-file tests themselves.
///
/// Every expectation in `Golden/` is written by hand from the specification,
/// and the `.in` file cites the behaviour it anchors. Nothing here is
/// generated from Corta's own output.
@Suite("Golden files")
struct GoldenTests {
    static let cases: [Golden.Case] = [
        Golden.Case("plain-text", rows: 5, columns: 12),
        Golden.Case("cursor-movement", rows: 4, columns: 10),
        Golden.Case("erase-line", rows: 4, columns: 10),
        Golden.Case("erase-display", rows: 4, columns: 10),
    ]

    @Test("golden files match", arguments: cases)
    func goldenFilesMatch(_ testCase: Golden.Case) throws {
        try Golden.verify(testCase)
    }

    // MARK: - The harness itself

    /// A golden test is only useful if a broken grid produces a diff that
    /// points at the damage. This is that check, without breaking the grid:
    /// the same case dumped from a terminal fed one byte less.
    @Test("a divergence is reported as a readable diff")
    func divergenceIsReadable() throws {
        let expected = try Golden.run(Golden.Case("plain-text", rows: 5, columns: 12)).dump()

        var damaged = Terminal(rows: 5, columns: 12)
        damaged.feed(Array("hello\tworld\r\n".utf8))
        let report = Golden.diff(expected: expected, actual: damaged.dump())

        #expect(report.contains("line 2:"))
        #expect(report.contains("cursor: row 4 column 1"))
        #expect(report.contains("cursor: row 2 column 0"))
        #expect(report.contains("|abdef       |"))
    }

    @Test("an identical dump reports no difference")
    func identicalDumpsReportNothing() {
        #expect(Golden.diff(expected: "a\nb\n", actual: "a\nb\n") == "(identical)")
    }

    // MARK: - The input encoding

    @Test("input escapes decode to the bytes they name")
    func inputEscapesDecode() throws {
        #expect(try Golden.decode("\\e[31m") == [0x1B, 0x5B, 0x33, 0x31, 0x6D])
        #expect(try Golden.decode("\\a\\b\\t\\n\\v\\f\\r\\0") == [7, 8, 9, 10, 11, 12, 13, 0])
        #expect(try Golden.decode("\\x9c\\xFF") == [0x9C, 0xFF])
        #expect(try Golden.decode("a\\\\b") == [0x61, 0x5C, 0x62])
    }

    /// Layout in the file is not input: a case is written over several lines
    /// so it can be read in a diff, and a newline in the stream is `\n`.
    @Test("literal newlines and comments are not input")
    func layoutIsNotInput() throws {
        #expect(try Golden.decode("# a comment\nab\ncd\n") == [0x61, 0x62, 0x63, 0x64])
    }

    @Test("a malformed escape is an error, not a wrong byte")
    func malformedEscapesThrow() {
        #expect(throws: Golden.DecodeError.self) { try Golden.decode("\\q") }
        #expect(throws: Golden.DecodeError.self) { try Golden.decode("\\") }
        #expect(throws: Golden.DecodeError.self) { try Golden.decode("\\xZZ") }
    }
}
