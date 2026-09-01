import Testing

@testable import CortaTerminal

/// M2.8 — OSC 0/2 window title and OSC 7 working directory. Set only: the
/// title query is never implemented (`SECURITY.md` §2.2), and no OSC ever
/// produces output bytes.
@Suite("OSC")
struct OSCTests {
    private func terminal(_ source: String) throws -> Terminal {
        var terminal = Terminal()
        terminal.feed(try Golden.decode(source))
        return terminal
    }

    @Test("OSC 0 and OSC 2 set the window title, BEL or ST terminated")
    func windowTitle() throws {
        #expect(try terminal("\\e]2;first\\a").windowTitle == "first")
        // ESC \ — the seven-bit ST.
        #expect(try terminal("\\e]0;second\\e\\\\").windowTitle == "second")
    }

    @Test("a later title replaces the earlier one")
    func titleIsReplaced() throws {
        #expect(try terminal("\\e]2;a\\a\\e]2;b\\a").windowTitle == "b")
    }

    @Test("an empty title clears it")
    func emptyTitle() throws {
        #expect(try terminal("\\e]2;a\\a\\e]2;\\a").windowTitle == "")
    }

    @Test("OSC 1 is ignored")
    func iconTitleIsIgnored() throws {
        #expect(try terminal("\\e]1;icon\\a").windowTitle == nil)
    }

    @Test("OSC 7 sets the working directory from a file URL")
    func workingDirectory() throws {
        #expect(
            try terminal("\\e]7;file://host/Users/noah/work\\a").workingDirectory
                == "/Users/noah/work"
        )
        // Percent-decoded.
        #expect(
            try terminal("\\e]7;file:///Users/My%20Name\\a").workingDirectory
                == "/Users/My Name"
        )
    }

    @Test("OSC 7 with a non-file scheme is ignored")
    func nonFileSchemeIsIgnored() throws {
        #expect(try terminal("\\e]7;https://example.com/x\\a").workingDirectory == nil)
        #expect(try terminal("\\e]7;not a url\\a").workingDirectory == nil)
    }

    @Test("no OSC produces output")
    func noOutput() throws {
        var terminal = try terminal("\\e]2;title\\a\\e]7;file:///tmp\\a")
        #expect(terminal.takeOutput().isEmpty)
    }

    /// The canonical exhaustion case at the terminal level (`SECURITY.md`
    /// §3): an overlong OSC is discarded wholesale — the title is not set —
    /// and the stream resynchronises on the terminator.
    @Test("an overlong OSC is discarded and the stream resynchronises")
    func overlongOSCIsDiscarded() throws {
        let payload = String(repeating: "A", count: Parser.maxStringLength + 100)
        let terminal = try terminal("\\e]2;" + payload + "\\aok")
        #expect(terminal.windowTitle == nil)
        #expect(terminal.grid[0, 0].scalar == 0x6F)
        #expect(terminal.grid[0, 1].scalar == 0x6B)
    }

    @Test("control bytes inside an OSC are dropped, not executed")
    func controlBytesAreDropped() throws {
        // 0x01 would be a C0 control in the ground state; inside a title it
        // is data, and it is dropped by the parser rather than executed.
        #expect(try terminal("\\e]2;a\\x01b\\a").windowTitle == "ab")
    }

    @Test("invalid UTF-8 in a title becomes the replacement character")
    func invalidUTF8() throws {
        #expect(try terminal("\\e]2;a\\xFFb\\a").windowTitle == "a\u{FFFD}b")
    }
}
