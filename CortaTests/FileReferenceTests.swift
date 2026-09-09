import AppKit
import CortaTerminal
import Testing

@testable import Corta

/// U17 — resolving a `path:line` reference to a file on *this* machine, and
/// refusing when it is not one.
///
/// The refusals are the interesting half. A path in a pane's output names a
/// file on whichever machine produced it; opening the same path locally after
/// an `ssh` would open a different file that happens to share a name.
@MainActor
struct FileReferenceResolutionTests {
    private static func reference(_ path: String, line: Int = 12) -> FileReferenceDetection.Reference {
        FileReferenceDetection.Reference(
            path: path, line: line,
            range: SelectionRange(
                anchor: SelectionPoint(row: 0, column: 0),
                head: SelectionPoint(row: 0, column: 5)))
    }

    @Test("a relative path resolves against the pane's directory")
    func relativeResolution() throws {
        let resolved = try #require(
            ViewController.resolve(
                Self.reference("b.txt"), directory: "/tmp/a",
                isRegularFile: { $0 == "/tmp/a/b.txt" }))
        #expect(resolved.url.path == "/tmp/a/b.txt")
        #expect(resolved.line == 12)
    }

    @Test("an absolute path is taken as it is")
    func absoluteResolution() throws {
        let resolved = try #require(
            ViewController.resolve(
                Self.reference("/etc/hosts"), directory: "/tmp",
                isRegularFile: { $0 == "/etc/hosts" }))
        #expect(resolved.url.path == "/etc/hosts")
    }

    /// **The remote case.** `TerminalSession.workingDirectory` is
    /// host-filtered, so a pane inside `ssh` reports `nil` — and an *absolute*
    /// path is refused there too, because an absolute path on another machine
    /// is no more this machine's than a relative one.
    @Test("a pane with no local directory resolves nothing")
    func remotePanesRefuse() {
        #expect(
            ViewController.resolve(
                Self.reference("src/main.rs"), directory: nil, isRegularFile: { _ in true })
                == nil)
        #expect(
            ViewController.resolve(
                Self.reference("/etc/hosts"), directory: nil, isRegularFile: { _ in true })
                == nil)
    }

    /// A path that does not name a file here is not opened — which is also
    /// what makes a same-named file on a remote host harmless if a directory
    /// ever did leak through: the check is against this filesystem.
    @Test("a path that is not a file here is refused")
    func missingFilesRefuse() {
        #expect(
            ViewController.resolve(
                Self.reference("nope.txt"), directory: "/tmp", isRegularFile: { _ in false })
                == nil)
    }

    /// A directory is not a file to open at a line number.
    @Test("a directory is not a reference") func directoriesRefuse() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-ref-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(
            ViewController.resolve(
                Self.reference(directory.lastPathComponent),
                directory: directory.deletingLastPathComponent().path) == nil)
    }

    /// The resolved path is what is checked *and* what is opened, so the two
    /// can never be different strings — a `..` that leaves the directory is
    /// visible in the result rather than hidden in it.
    @Test("the path is standardized before it is checked")
    func pathsAreStandardized() throws {
        var checked: [String] = []
        let resolved = try #require(
            ViewController.resolve(
                Self.reference("../sibling/x.txt"), directory: "/tmp/a",
                isRegularFile: { path in
                    checked.append(path)
                    return path == "/tmp/sibling/x.txt"
                }))
        #expect(checked == ["/tmp/sibling/x.txt"])
        #expect(resolved.url.path == "/tmp/sibling/x.txt")
    }

    @Test("a real file on this machine resolves end to end")
    func realFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-ref-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("main.swift")
        try "let x = 1\n".write(to: file, atomically: true, encoding: .utf8)

        let resolved = try #require(
            ViewController.resolve(Self.reference("main.swift", line: 3), directory: directory.path))
        #expect(resolved.url.lastPathComponent == "main.swift")
        #expect(resolved.line == 3)
    }
}

/// The configured open command: substitution, and the shell that is never
/// involved.
@MainActor
struct OpenFileCommandTests {
    @Test("placeholders are substituted per argument")
    func substitution() {
        let arguments = ViewController.openFileArguments(
            template: "/usr/bin/xed --line {line} {file}", path: "/tmp/a b.swift", line: 42,
            column: nil)
        #expect(arguments == ["/usr/bin/xed", "--line", "42", "/tmp/a b.swift"])
    }

    /// The template is split, the *value* never is — so a path with a space
    /// stays one argument. Nothing is passed through a shell, so the path's
    /// metacharacters never mean anything again.
    @Test("a path with spaces and metacharacters stays one argument")
    func hostilePaths() {
        let arguments = ViewController.openFileArguments(
            template: "/bin/editor {file}", path: "/tmp/a; rm -rf ~/b.swift", line: 1,
            column: nil)
        #expect(arguments == ["/bin/editor", "/tmp/a; rm -rf ~/b.swift"])
    }

    @Test("the column defaults to 1 when the output named none")
    func columnDefault() {
        let arguments = ViewController.openFileArguments(
            template: "/bin/e -l {line} -c {column} {file}", path: "/tmp/x", line: 9, column: nil)
        #expect(arguments == ["/bin/e", "-l", "9", "-c", "1", "/tmp/x"])
        let withColumn = ViewController.openFileArguments(
            template: "/bin/e -c {column} {file}", path: "/tmp/x", line: 9, column: 4)
        #expect(withColumn == ["/bin/e", "-c", "4", "/tmp/x"])
    }

    @Test("the setting round-trips through the config file")
    func configKey() {
        let (parsed, unknown) = Configuration.parse("open-file-command = /usr/bin/xed --line {line} {file}")
        #expect(unknown.isEmpty)
        #expect(parsed.openFileCommand == "/usr/bin/xed --line {line} {file}")
        #expect(Configuration().openFileCommand.isEmpty)
        let (reparsed, _) = Configuration.parse(parsed.serialized())
        #expect(reparsed.openFileCommand == parsed.openFileCommand)
    }

    /// Review finding. The validator split on the space alone while the
    /// launcher runs the first *whitespace*-separated word. The invariant
    /// that matters is that the two agree: whatever the validator judged is
    /// what gets executed, so a template the config file accepts is one the
    /// app can actually run.
    @Test("the words the validator judges are the words the launcher runs")
    func validatorAndLauncherSplitAlike() {
        let templates = [
            "/usr/bin/xed {file}",
            "/usr/bin/xed\t--line\t{line}\t{file}",
            "/usr/bin/xed\n{file}",
            "  /usr/bin/xed   {file}  ",
        ]
        for template in templates {
            let judged = Configuration.isUsableOpenFileCommand(template)
            let arguments = ViewController.openFileArguments(
                template: template, path: "/tmp/x", line: 3, column: nil)
            // Accepted means the first word the launcher will exec is the
            // absolute path the validator approved.
            #expect(judged, "\(template.debugDescription) should be usable")
            #expect(arguments.first == "/usr/bin/xed", "\(template.debugDescription)")
            #expect(arguments.last == "/tmp/x", "\(template.debugDescription)")
        }
        // A relative first word is refused however it is spaced, and the
        // config file keeps the default rather than storing it.
        #expect(!Configuration.isUsableOpenFileCommand("\txed {file}"))
        let (parsed, _) = Configuration.parse("open-file-command = xed {file}")
        #expect(parsed.openFileCommand.isEmpty)
    }

    /// The URL scheme allowlist is not widened by any of this: a `file://`
    /// string in output is still plain text, and still cannot be detected as
    /// a link at all.
    @Test("output cannot hand NSWorkspace a file URL")
    func schemeAllowlistIsUnchanged() {
        var terminal = Terminal(rows: 4, columns: 60, scrollbackLimit: 10)
        terminal.feed(Array("file:///etc/passwd and custom://x".utf8))
        let line = terminal.grid.logicalLine(containing: 0)
        #expect(LinkDetection.links(in: line).isEmpty)
    }
}
