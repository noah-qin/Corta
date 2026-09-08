import AppKit
import CortaTerminal
import Testing

@testable import Corta

/// U17 — the remote case, staged through the input a real `ssh` session
/// actually supplies.
///
/// The earlier record said "no ssh session was staged" and asserted the
/// refusal through a `nil` directory handed in by hand. That skipped the
/// step that matters: whether a *real* OSC 7 report from a remote host
/// produces that `nil` in the first place. It is the parser that decides,
/// and the parser can be driven from here with the exact bytes an `ssh`
/// session emits — no daemon, no network, and no change to the machine,
/// which the project's own rule forbids.
struct RemoteWorkingDirectoryTests {
    private static func terminal(feeding bytes: String) -> Terminal {
        var terminal = Terminal(rows: 8, columns: 40, scrollbackLimit: 50)
        terminal.feed(Array(bytes.utf8))
        return terminal
    }

    /// What a shell reports on this machine: a `file://` URL whose host is
    /// the local hostname, or empty, or `localhost`.
    @Test("a local OSC 7 report becomes a directory")
    func localReportsResolve() {
        let host = ProcessInfo.processInfo.hostName
        for authority in ["", "localhost", host] {
            let terminal = Self.terminal(feeding: "\u{1B}]7;file://\(authority)/tmp\u{7}")
            #expect(
                terminal.workingDirectory == "/tmp",
                "file://\(authority)/tmp should resolve")
        }
    }

    /// What the same shell reports **through `ssh`**: the remote machine's
    /// hostname and the remote machine's path. Dropped, because that path
    /// names a file on a different computer.
    @Test("an OSC 7 report from a remote host is dropped")
    func remoteReportsAreDropped() {
        for authority in ["build-box", "build-box.internal", "192.168.1.40", "user@host"] {
            let terminal = Self.terminal(feeding: "\u{1B}]7;file://\(authority)/srv/app\u{7}")
            #expect(
                terminal.workingDirectory == nil,
                "file://\(authority)/srv/app should be dropped")
        }
    }

    /// End to end: the bytes an `ssh` session emits, then a `path:line`
    /// reference in that session's output. The reference resolves to nothing,
    /// which is the whole safety property — the path names a file on the
    /// remote machine, and a same-named local file is a different file.
    @MainActor
    @Test("a file reference printed inside an ssh session opens nothing")
    func referencesInsideAnSSHSessionRefuse() throws {
        var terminal = Terminal(rows: 8, columns: 60, scrollbackLimit: 50)
        // The remote shell announces where it is, then a compiler on that
        // machine prints an error.
        terminal.feed(Array("\u{1B}]7;file://build-box/srv/app\u{7}".utf8))
        terminal.feed(Array("src/main.rs:42:17: error: no method\r\n".utf8))
        #expect(terminal.workingDirectory == nil)

        let line = terminal.grid.logicalLine(containing: 0)
        let reference = try #require(FileReferenceDetection.references(in: line).first)
        #expect(reference.path == "src/main.rs")
        // The path is detected — it is a real reference, on the remote box —
        // and resolves to nothing here, even though `/tmp` exists locally and
        // a same-named file might too.
        #expect(
            ViewController.resolve(
                reference, directory: terminal.workingDirectory,
                isRegularFile: { _ in true }) == nil)
    }

    /// And the local session, for contrast: same output, a local OSC 7, and
    /// the reference resolves.
    @MainActor
    @Test("the same output in a local session resolves")
    func referencesInALocalSessionResolve() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "fn main() {}\n".write(
            to: directory.appendingPathComponent("src/main.rs"), atomically: true, encoding: .utf8)

        var terminal = Terminal(rows: 8, columns: 60, scrollbackLimit: 50)
        terminal.feed(Array("\u{1B}]7;file://localhost\(directory.path)\u{7}".utf8))
        terminal.feed(Array("src/main.rs:42:17: error: no method\r\n".utf8))
        let reported = try #require(terminal.workingDirectory)

        let line = terminal.grid.logicalLine(containing: 0)
        let reference = try #require(FileReferenceDetection.references(in: line).first)
        let resolved = try #require(ViewController.resolve(reference, directory: reported))
        #expect(resolved.url.lastPathComponent == "main.rs")
        #expect(resolved.line == 42)
        #expect(resolved.column == 17)
    }
}

/// U09 — the shell/directory fallback ladder, staged with a shell that does
/// not exist and a directory that does not exist.
///
/// The earlier record said the ladder was "verified by inspection", because
/// staging it appeared to need `$SHELL` changed — which the project's rule
/// forbids doing to the machine. It does not: the ladder's first rung is now
/// a parameter, so the failing ingredients can be supplied to the call
/// instead of to the environment, and the spawns are real.
@MainActor
@Suite(.serialized)
struct SpawnFallbackLadderTests {
    @Test("a shell that does not exist falls back, and says so")
    func missingShellFallsBack() throws {
        let started = try ViewController.startSession(
            size: TerminalSize(rows: 24, columns: 80),
            directory: NSHomeDirectory(), scrollbackLimit: 100,
            configuredShell: "/nonexistent/shell")
        defer { started.session.stop() }
        #expect(started.notice != nil, "a fallback must be reported, not silent")
        #expect(started.session.pty.processIdentifier > 0)
    }

    @Test("a directory that does not exist falls back to home")
    func missingDirectoryFallsBack() throws {
        let started = try ViewController.startSession(
            size: TerminalSize(rows: 24, columns: 80),
            directory: "/no/such/directory/here", scrollbackLimit: 100)
        defer { started.session.stop() }
        #expect(started.notice != nil)
        #expect(started.session.pty.processIdentifier > 0)
    }

    /// Both ingredients bad at once — the case that used to abort the whole
    /// pane. The ladder drops one, then the other.
    @Test("a bad shell and a bad directory still produce a terminal")
    func bothBadStillStarts() throws {
        let started = try ViewController.startSession(
            size: TerminalSize(rows: 24, columns: 80),
            directory: "/no/such/directory/here", scrollbackLimit: 100,
            configuredShell: "/nonexistent/shell")
        defer { started.session.stop() }
        #expect(started.notice != nil)
        #expect(started.session.pty.processIdentifier > 0)
    }

    /// A working shell and directory take the first rung and report nothing:
    /// a notice on an ordinary launch would be noise.
    @Test("the ordinary case reports no fallback")
    func ordinaryCaseIsSilent() throws {
        let started = try ViewController.startSession(
            size: TerminalSize(rows: 24, columns: 80),
            directory: NSHomeDirectory(), scrollbackLimit: 100,
            configuredShell: "/bin/zsh")
        defer { started.session.stop() }
        #expect(started.notice == nil)
    }
}
