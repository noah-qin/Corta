import Testing

@testable import CortaTerminal

/// M2.2 — DA1, DA2 and DSR-CPR (`CONFORMANCE.md` §1.2). The exact response
/// bytes are asserted without a PTY: the performer queues them on the
/// terminal, and `takeOutput` is what the session writes.
@Suite("Query responses")
struct QueryResponseTests {
    private func output(_ source: String, rows: Int = 24, columns: Int = 80) throws -> [UInt8] {
        var terminal = Terminal(rows: rows, columns: columns)
        terminal.feed(try Golden.decode(source))
        return terminal.takeOutput()
    }

    /// ctlseqs, "Send Device Attributes (Primary DA)": `CSI ? 62 ; Ps c` is
    /// the VT220 form; 1 = 132 columns, 22 = ANSI colour.
    @Test("DA1 answers VT220 with 132 columns and ANSI colour")
    func primaryDeviceAttributes() throws {
        #expect(try output("\\e[c") == Array("\u{1B}[?62;1;22c".utf8))
        #expect(try output("\\e[0c") == Array("\u{1B}[?62;1;22c".utf8))
    }

    /// ctlseqs, "Send Device Attributes (Secondary DA)":
    /// `CSI > Pp ; Pv ; Pc c`. Pp 1 = VT220, matching DA1.
    @Test("DA2 answers VT220, no version, no cartridge")
    func secondaryDeviceAttributes() throws {
        #expect(try output("\\e[>c") == Array("\u{1B}[>1;0;0c".utf8))
        #expect(try output("\\e[>0c") == Array("\u{1B}[>1;0;0c".utf8))
    }

    @Test("the cursor-position report is one-based")
    func cursorPositionReport() throws {
        #expect(try output("\\e[6n") == Array("\u{1B}[1;1R".utf8))
        #expect(try output("\\e[3;5H\\e[6n") == Array("\u{1B}[3;5R".utf8))
        #expect(try output("ab\\e[6n") == Array("\u{1B}[1;3R".utf8))
    }

    @Test("queries in one stream answer in order")
    func queriesConcatenate() throws {
        #expect(
            try output("\\e[c\\e[6n\\e[>c")
                == Array("\u{1B}[?62;1;22c\u{1B}[1;1R\u{1B}[>1;0;0c".utf8)
        )
    }

    @Test("takeOutput drains the queue")
    func takeOutputDrains() throws {
        var terminal = Terminal()
        #expect(!terminal.hasPendingOutput)
        terminal.feed(try Golden.decode("\\e[c"))
        #expect(terminal.hasPendingOutput)
        #expect(!terminal.takeOutput().isEmpty)
        #expect(!terminal.hasPendingOutput)
        #expect(terminal.takeOutput().isEmpty)
    }

    /// DSR 5 (status), a bare `CSI n`, DECXCPR (`CSI ? 6 n`) and the title
    /// query all stay silent — the title query deliberately so
    /// (`SECURITY.md` §2.2).
    @Test("other queries get no answer")
    func unimplementedQueriesAreSilent() throws {
        #expect(try output("\\e[5n").isEmpty)
        #expect(try output("\\e[n").isEmpty)
        #expect(try output("\\e[?6n").isEmpty)
        #expect(try output("\\e[21t").isEmpty)
    }

    /// Even when the stream sets state and immediately asks questions, the
    /// answer is fixed bytes only (`SECURITY.md` §2.1).
    @Test("a response never echoes stream text")
    func responseNeverEchoesInput() throws {
        let bytes = try output("\\e]2;rm -rf /\\a\\e[c\\e[6n")
        #expect(bytes == Array("\u{1B}[?62;1;22c\u{1B}[1;1R".utf8))
    }
}
