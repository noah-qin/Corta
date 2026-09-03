import Testing

@testable import CortaTerminal

/// Every query a child can send, answered or cleanly ignored — and never
/// left hanging.
///
/// The failure this guards against is not a wrong answer, it is *no* answer.
/// A program that sends DECRQM or DA and waits for a reply with a timeout
/// stalls for that timeout; one that waits without a timeout — and several
/// do — hangs until it is killed, and the terminal looks like the thing that
/// froze. So the rule is: a query either produces a complete, terminated
/// response or produces nothing at all, and in neither case does feeding it
/// leave the parser mid-sequence.
@Suite("Query robustness")
struct QueryRobustnessTests {
    private func response(to input: String) throws -> [UInt8] {
        var terminal = Terminal(rows: 4, columns: 20)
        terminal.feed(try Golden.decode(input))
        return terminal.takeOutput()
    }

    /// DECRQM's contract is that *every* mode number gets an answer, because
    /// "I do not recognise that mode" is itself one of the five answers (0).
    /// Silence is the only reply that hurts.
    @Test("DECRQM answers every mode number, known or not")
    func decrqmAlwaysAnswers() throws {
        for mode in [0, 1, 2, 4, 12, 20, 34, 99, 1049, 2026, 65535] {
            let ansi = try response(to: "\\e[\(mode)$p")
            #expect(!ansi.isEmpty, "ANSI mode \(mode) went unanswered")
            #expect(ansi.last == UInt8(ascii: "y"), "ANSI mode \(mode) answer unterminated")
            let priv = try response(to: "\\e[?\(mode)$p")
            #expect(!priv.isEmpty, "private mode \(mode) went unanswered")
            #expect(priv.last == UInt8(ascii: "y"), "private mode \(mode) answer unterminated")
        }
    }

    /// A response is a fixed-format byte string; a truncated one is as bad as
    /// none, because the program is still waiting for the terminator.
    @Test("every answered query ends in its own terminator")
    func answersAreTerminated() throws {
        let cases: [(input: String, terminator: [UInt8])] = [
            ("\\e[c", Array("c".utf8)),  // DA1
            ("\\e[>c", Array("c".utf8)),  // DA2
            ("\\e[6n", Array("R".utf8)),  // DSR cursor position
            ("\\e[5n", Array("n".utf8)),  // DSR operating status
            ("\\e[?6n", Array("R".utf8)),  // DECXCPR
            ("\\e[18t", Array("t".utf8)),  // window size in characters
            ("\\e[?u", Array("u".utf8)),  // kitty keyboard flags
            ("\\e[>0q", [0x1B, 0x5C]),  // XTVERSION, ST-terminated
            ("\\e]10;?\\e\\\\", [0x1B, 0x5C]),  // OSC 10 query
            ("\\e]11;?\\e\\\\", [0x1B, 0x5C]),
            ("\\e]12;?\\e\\\\", [0x1B, 0x5C]),
        ]
        for (input, terminator) in cases {
            let answer = try response(to: input)
            #expect(!answer.isEmpty, "\(input) went unanswered")
            #expect(answer.suffix(terminator.count) == terminator.suffix(terminator.count),
                "\(input) answer unterminated")
        }
    }

    /// The queries Corta refuses to answer stay refused, and refuse *quietly*
    /// — the point of not answering the title query is that the answer is a
    /// command-injection vector (`SECURITY.md` §2.2), and an error reply
    /// would be a reply.
    @Test("the deliberately unanswered queries produce nothing at all")
    func withheldQueriesProduceNoBytes() throws {
        // OSC 21 (title report) and OSC 52 read, both withheld by design.
        #expect(try response(to: "\\e]21;?\\e\\\\").isEmpty)
        #expect(try response(to: "\\e]52;c;?\\e\\\\").isEmpty)
    }

    /// A colour specification Corta will not convert changes nothing and
    /// says nothing — the P2 colour-space governance in
    /// `parseColorSpecification`. The risk being guarded here is a *partial*
    /// parse: reading `rgbi:1.0/0/0` as hex would set a colour the program
    /// never asked for, and reading `CIELab:` as anything at all would set a
    /// wrong one.
    @Test("refused colour spaces leave the colour untouched and answer nothing")
    func refusedColorSpacesAreInert() throws {
        for specification in [
            "rgbi:1.0/0.5/0.0", "CIELab:50.0/20.0/-30.0", "CIEuvY:0.2/0.3/0.5",
            "CIExyY:0.3/0.3/0.5", "CIEXYZ:0.4/0.4/0.4", "TekHVC:120.0/50.0/60.0",
        ] {
            var terminal = Terminal(rows: 2, columns: 10)
            let before = terminal.dynamicColors
            terminal.feed(try Golden.decode("\\e]11;\(specification)\\e\\\\"))
            #expect(terminal.takeOutput().isEmpty, "\(specification) produced output")
            #expect(terminal.dynamicColors.background == before.background,
                "\(specification) changed the background")
        }
    }

    /// A truncated or malformed query must not leave the parser waiting: the
    /// next ordinary text has to land on the grid.
    @Test("a malformed query does not swallow what follows")
    func malformedQueriesDoNotStickTheParser() throws {
        for prefix in [
            "\\e[", "\\e[?", "\\e[?25", "\\e[?25$", "\\e]", "\\e]11;", "\\e]11;?", "\\e[>",
            "\\e[999999999999;999999999999$p",
        ] {
            var terminal = Terminal(rows: 2, columns: 20)
            // A CAN cancels whatever sequence was in flight; without it the
            // text would legitimately be read as more parameters.
            terminal.feed(try Golden.decode("\(prefix)\\x18ok"))
            #expect(terminal.grid.rowText(0).hasSuffix("ok"), "\(prefix) swallowed the text")
        }
    }
}
