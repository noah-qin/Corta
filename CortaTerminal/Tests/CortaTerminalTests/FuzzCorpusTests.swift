import Foundation
import Testing

@testable import CortaTerminal

/// M6.11 — the checked-in fuzz corpus, run on every test pass.
///
/// The long runs live in the `corta-fuzz` executable (millions of mutated
/// inputs, and the `LLVMFuzzerTestOneInput` entry point for a toolchain that
/// has libFuzzer — Xcode 26 does not ship one for macOS, see that target's
/// comment). What belongs here is the part that must never regress silently:
/// every input the fuzzer has already found interesting, replayed, with the
/// `SECURITY.md` §3 caps asserted.
///
/// A crash found by a long run is fixed by adding its input to the corpus
/// directory, which puts it in this test from then on.
@Suite("Fuzz corpus")
struct FuzzCorpusTests {
    private static let corpusDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // CortaTerminalTests
        .deletingLastPathComponent()  // Tests
        .appendingPathComponent("Fuzz/corpus")

    private static func corpus() throws -> [(name: String, bytes: [UInt8])] {
        let names = try FileManager.default
            .contentsOfDirectory(atPath: corpusDirectory.path)
            .filter { $0.hasSuffix(".bin") }
            .sorted()
        return names.map { name in
            let data =
                FileManager.default.contents(
                    atPath: corpusDirectory.appendingPathComponent(name).path) ?? Data()
            return (name, Array(data))
        }
    }

    /// Feeds `bytes` in chunks derived from the input itself — a chunk
    /// boundary may fall in the middle of a UTF-8 character or an escape
    /// sequence, which is where the decoder's state machine goes wrong.
    private func feedAndCheckCaps(_ bytes: [UInt8], name: String) {
        let rows = 24
        let columns = 80
        let scrollbackLimit = 64
        var terminal = Terminal(rows: rows, columns: columns, scrollbackLimit: scrollbackLimit)
        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + 1 + Int(bytes[offset]) % 17)
            terminal.feed(bytes[offset..<end])
            offset = end
        }

        let grid = terminal.grid
        #expect(grid.rows == rows, "\(name): the grid resized itself")
        #expect(grid.columns == columns, "\(name): the grid resized itself")
        #expect(grid.scrollback.count <= scrollbackLimit, "\(name): scrollback past its ring")
        #expect(grid.cursor.row >= 0 && grid.cursor.row < rows, "\(name): cursor row escaped")
        #expect(
            grid.cursor.column >= 0 && grid.cursor.column <= columns,
            "\(name): cursor column escaped")
        for row in 0..<rows {
            #expect(grid.line(row).count <= columns, "\(name): row \(row) grew past the width")
        }
        #expect(grid.graphemes.count <= GraphemeTable.capacity, "\(name): grapheme table unbounded")
        #expect(grid.hyperlinks.count <= HyperlinkTable.capacity, "\(name): link table unbounded")
        #expect(terminal.takeOutput().count <= 64 * 1024, "\(name): queued too much response")
    }

    @Test("every corpus input parses without crashing and leaves the caps intact")
    func corpusHoldsTheCaps() throws {
        let corpus = try Self.corpus()
        #expect(!corpus.isEmpty, "the corpus directory must not be empty")
        for entry in corpus { feedAndCheckCaps(entry.bytes, name: entry.name) }
    }

    /// The canonical resource-exhaustion case from `SECURITY.md` §3: a
    /// stream that opens an OSC and never closes it must not accumulate.
    @Test("an unterminated OSC string does not accumulate")
    func unterminatedOSCIsBounded() {
        var terminal = Terminal(rows: 24, columns: 80, scrollbackLimit: 64)
        terminal.feed(Array("\u{1B}]0;".utf8))
        for _ in 0..<1000 { terminal.feed(Array(repeating: 0x41, count: 1024)) }
        // The parser discards an over-long string and resynchronises, so the
        // title is never set and normal text after it still lands.
        terminal.feed(Array("\u{1B}\\hello".utf8))
        #expect(terminal.windowTitle == nil)
        #expect(terminal.dump().contains("hello"))
    }
}
