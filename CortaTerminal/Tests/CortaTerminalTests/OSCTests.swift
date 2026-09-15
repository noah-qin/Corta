import Foundation
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

    @Test("OSC 7 sets the working directory from a local file URL")
    func workingDirectory() throws {
        // An empty host, and `localhost`, both name this machine.
        #expect(
            try terminal("\\e]7;file:///Users/noah/work\\a").workingDirectory
                == "/Users/noah/work"
        )
        #expect(
            try terminal("\\e]7;file://localhost/Users/noah/work\\a").workingDirectory
                == "/Users/noah/work"
        )
        // Percent-decoded.
        #expect(
            try terminal("\\e]7;file:///Users/My%20Name\\a").workingDirectory
                == "/Users/My Name"
        )
        // This machine's own hostname, as `ProcessInfo` reports it.
        let own = ProcessInfo.processInfo.hostName
        #expect(try terminal("\\e]7;file://\(own)/tmp\\a").workingDirectory == "/tmp")
    }

    @Test("OSC 7 from a remote host is recorded as remote context, isolated from spawn paths")
    func remoteWorkingDirectoryIsRecordedAsRemoteContext() throws {
        // A shell over ssh reports a directory on the remote host; the path
        // must never seed a local spawn or a restored session, but the report
        // itself is kept so the app can show which host the pane refers to.
        var remote = try terminal("\\e]7;file://host/Users/noah/work\\a")
        #expect(remote.workingDirectory == nil)
        #expect(remote.remoteContext?.host == "host")
        #expect(remote.remoteContext?.directory == "/Users/noah/work")
        #expect(remote.remoteContext?.provenance == .osc7)

        remote = try terminal("\\e]7;file://PROD.example.com./var/www\\a")
        #expect(remote.workingDirectory == nil)
        // The host is normalised the way host matching normalises everything
        // else; the path is preserved as reported, percent-decoded.
        #expect(remote.remoteContext?.host == "prod.example.com")
        #expect(remote.remoteContext?.directory == "/var/www")

        // The latest remote report wins.
        remote = try terminal(
            "\\e]7;file://host/one\\a\\e]7;file://other-host/two\\a")
        #expect(remote.remoteContext?.host == "other-host")
        #expect(remote.remoteContext?.directory == "/two")

        // A remote report does not displace a directory already accepted.
        remote = try terminal("\\e]7;file:///tmp\\a\\e]7;file://host/elsewhere\\a")
        #expect(remote.workingDirectory == "/tmp")
        #expect(remote.remoteContext?.host == "host")
        #expect(remote.remoteContext?.directory == "/elsewhere")
    }

    @Test("a local OSC 7 report clears a recorded remote context")
    func localReportClearsRemoteContext() throws {
        let terminal = try terminal(
            "\\e]7;file://host/srv/app\\a\\e]7;file:///tmp\\a")
        #expect(terminal.workingDirectory == "/tmp")
        #expect(terminal.remoteContext == nil)
    }

    @Test("OSC 7 host matching is case-insensitive and ignores a trailing dot")
    func hostMatching() {
        let local: Set<String> = ["localhost", "noahs-mac", "noahs-mac.local"]
        #expect(Performer.isLocalHost("", localNames: local))
        #expect(Performer.isLocalHost("LOCALHOST", localNames: local))
        #expect(Performer.isLocalHost("Noahs-Mac", localNames: local))
        // The FQDN form a shell may report, with and without the root dot.
        #expect(Performer.isLocalHost("noahs-mac.local.", localNames: local))
        #expect(Performer.isLocalHost("NOAHS-MAC.LOCAL", localNames: local))
        #expect(!Performer.isLocalHost("prod.example.com", localNames: local))
        #expect(!Performer.isLocalHost("noahs-mac2", localNames: local))
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
