import Darwin
import Dispatch
import Testing

@testable import CortaTerminal

/// M1.1 — open a pty pair, spawn a child, read, write, close.
///
/// `.serialized`: every test here forks a real child process — see the
/// `.serialized` note on `TerminalSessionTests`.
@Suite("PTY", .serialized)
struct PTYTests {
    @Test("spawns /bin/echo and reads its output back")
    func spawnsEchoAndReadsOutput() throws {
        let pty = try PTY.spawn(executable: "/bin/echo", arguments: ["hello"])
        defer { pty.close() }

        let output = pty.readOutput(containing: "hello")
        // A terminal in its default mode translates NL to CR NL on output.
        #expect(output == "hello\r\n")
        #expect(pty.waitForExit() == .exited(code: 0))
    }

    @Test("reports end of file after the child exits")
    func readsEndOfFileAfterChildExits() throws {
        let pty = try PTY.spawn(executable: "/bin/echo", arguments: ["bye"])
        defer { pty.close() }

        _ = pty.waitForExit()
        _ = pty.readOutput(containing: "bye")

        // Darwin reports EIO on the primary side once the replica is gone;
        // `read` must present that as end of file, not as a failure.
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = try buffer.withUnsafeMutableBytes { try pty.read(into: $0) }
        #expect(count == 0)
    }

    @Test("input written to the pty reaches the child")
    func writesReachTheChild() throws {
        let pty = try PTYFixture.shell("read -r line; printf 'got:%s\\n' \"$line\"")
        defer { pty.close() }

        try pty.write(text: "corta\n")
        let output = pty.readOutput(containing: "got:")
        #expect(output.contains("got:corta"))
        #expect(pty.waitForExit() == .exited(code: 0))
    }

    @Test("the child leads a new session with the pty as its controlling terminal")
    func childOwnsAControllingTerminal() throws {
        // Opening /dev/tty succeeds only for a process that has a controlling
        // terminal; POSIX_SPAWN_SETSID plus the replica on fd 0 is what
        // establishes it (`SECURITY.md` §4.3).
        let pty = try PTYFixture.shell(
            "if (: < /dev/tty) 2>/dev/null; then echo CTTY-OK; fi; "
                + "ps -o pgid= -p $$; echo COMPLETE"
        )
        defer { pty.close() }

        let output = pty.readOutput(containing: "COMPLETE")
        #expect(output.contains("CTTY-OK"))

        // A session leader's process group id equals its pid.
        let groupIdentifier = fields(of: output).compactMap(pid_t.init).first
        #expect(groupIdentifier == pty.processIdentifier)
        #expect(pty.waitForExit() == .exited(code: 0))
    }

    @Test("the child's environment is sanitised and TERM is xterm-256color")
    func childEnvironmentIsSanitised() throws {
        let pty = try PTY.spawn(
            executable: "/usr/bin/env",
            environment: ChildEnvironment.sanitized(inheriting: [
                "PATH": "/usr/bin:/bin",
                "TERM": "inherited-and-wrong",
                "COLUMNS": "999",
                "CORTA_INTERNAL": "leak",
            ])
        )
        defer { pty.close() }

        let output = pty.readOutput(containing: "TERM=")
        #expect(output.contains("TERM=xterm-256color"))
        #expect(output.contains("TERM_PROGRAM=Corta"))
        #expect(output.contains("PATH=/usr/bin:/bin"))
        #expect(!output.contains("COLUMNS"))
        #expect(!output.contains("CORTA_INTERNAL"))
        #expect(pty.waitForExit() == .exited(code: 0))
    }

    @Test("spawning a relative executable path is rejected")
    func relativeExecutablePathIsRejected() {
        #expect(throws: PTYError.executablePathNotAbsolute) {
            try PTY.spawn(executable: "echo")
        }
    }

    @Test("spawning a missing executable reports the errno")
    func missingExecutableReportsErrno() {
        #expect(throws: PTYError.spawnFailed(code: ENOENT)) {
            try PTY.spawn(executable: "/nonexistent/corta-does-not-exist")
        }
    }

    @Test("close is idempotent")
    func closeIsIdempotent() throws {
        let pty = try PTY.spawn(executable: "/bin/echo", arguments: ["x"])
        _ = pty.waitForExit()
        pty.close()
        pty.close()
    }
}
