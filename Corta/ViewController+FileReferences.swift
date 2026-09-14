import Cocoa
import CortaTerminal

/// U17 — following `src/main.rs:42:17` from program output to the file.
///
/// **The local/remote distinction is the whole safety argument.** A path in a
/// pane's output names a file on whichever machine produced it. In an `ssh`
/// session that is not this Mac, and opening the same path locally would open
/// a *different file that happens to share a name* — at best confusing, at
/// worst editing the wrong thing in the wrong repository. Corta already knows
/// the difference: `TerminalSession.workingDirectory` is host-filtered
/// (S05) — an OSC 7 report naming a remote host produces `nil`, not a path —
/// so a pane with no local working directory has nothing to resolve against
/// and refuses rather than guessing.
///
/// **The URL scheme allowlist is untouched.** `SECURITY.md` §2.4 lets exactly
/// `http`, `https` and `mailto` reach `NSWorkspace`, because the *text* comes
/// from the child. Nothing here widens that: a file reference is never parsed
/// as a URL, and the `file:` URL that is eventually opened is built by Corta
/// from a path it has resolved against a known-local directory and confirmed
/// exists as a regular file. The child chooses the path, never the scheme,
/// and never whether the thing is a file at all.
extension ViewController {
    /// The reference under a point, already known to name a file that exists
    /// on this machine.
    struct ResolvedFileReference: Equatable {
        var url: URL
        var line: Int
        var column: Int?
        var range: SelectionRange
    }

    /// Resolves a detected reference against a directory, or refuses.
    ///
    /// Static and pure — the filesystem check is injected — so every refusal
    /// is testable without a pane, an `ssh` session or a fixture tree.
    ///
    /// - Parameter directory: the pane's working directory, already known to
    ///   be local. `nil` means the pane is somewhere Corta cannot resolve
    ///   against — a remote host, or a shell that has never reported one —
    ///   and an absolute path is *still* refused there, because an absolute
    ///   path on a remote host is no more this machine's than a relative one.
    static func resolve(
        _ reference: FileReferenceDetection.Reference, directory: String?,
        isRegularFile: (String) -> Bool = { path in
            var isDirectory = ObjCBool(false)
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            return exists && !isDirectory.boolValue
        }
    ) -> ResolvedFileReference? {
        guard let directory else { return nil }
        let expanded = (reference.path as NSString).expandingTildeInPath
        let absolute =
            expanded.hasPrefix("/")
            ? expanded
            : (directory as NSString).appendingPathComponent(expanded)
        // `standardizingPath` resolves `..`, which is what keeps a path from
        // *appearing* to stay under the directory while leaving it. It is not
        // a sandbox — the pane's own shell can read anything the user can —
        // but the resolved path is what gets checked and what gets opened, so
        // the two can never be different strings.
        let standardized = (absolute as NSString).standardizingPath
        guard isRegularFile(standardized) else { return nil }
        return ResolvedFileReference(
            url: URL(fileURLWithPath: standardized), line: reference.line,
            column: reference.column, range: reference.range)
    }

    /// The reference under a mouse event, resolved, or `nil`.
    func fileReferenceUnder(_ event: NSEvent, in terminalView: TerminalView)
        -> ResolvedFileReference?
    {
        guard let reference = detectedReferenceUnder(event, in: terminalView) else { return nil }
        return Self.resolve(reference, directory: session.workingDirectory)
    }

    /// The raw detection half of `fileReferenceUnder`, before resolution —
    /// shared with the remote path (`ViewController+RemoteEdit.swift`),
    /// which resolves against the pane's remote directory instead.
    func detectedReferenceUnder(_ event: NSEvent, in terminalView: TerminalView)
        -> FileReferenceDetection.Reference?
    {
        guard isOperable, let terminalRenderer else { return nil }
        let grid = session.snapshot()
        let point = Self.documentPosition(
            for: terminalView.convert(event.locationInWindow, from: nil),
            viewHeight: terminalView.bounds.height, metrics: terminalRenderer.pointMetrics,
            grid: grid, scrollOffset: scrollOffset, topInset: topInset)
        return FileReferenceDetection.reference(at: point, in: grid)
    }

    @discardableResult
    func open(_ reference: ResolvedFileReference) -> Bool {
        let opened = Self.openFileAt(
            url: reference.url, line: reference.line, column: reference.column)
        if !opened {
            terminalView?.showToast(L10n.text("toast.badOpenFileCommand"), kind: .warning)
        }
        return opened
    }

    /// Opens a local file in the editor, at the line if the configured
    /// command can take one — static so both the local file-reference path
    /// and the remote-edit coordinator (`RemoteEditCoordinator`, which
    /// opens *managed local copies* of remote files) go through the exact
    /// same `open-file-command` substitution.
    ///
    /// With no `open-file-command` configured this is `NSWorkspace.open`,
    /// which opens the user's default application for the type and cannot be
    /// told a line number — so the line is lost, and the tooltip says as
    /// much rather than implying otherwise. A configured command is run
    /// through `Process` with the path and line as separate arguments and
    /// **never through a shell**: the path came from program output, and a
    /// shell would make its metacharacters mean something again after all the
    /// work `SECURITY.md` §2.3 does to stop exactly that.
    @discardableResult
    static func openFileAt(url: URL, line: Int, column: Int?) -> Bool {
        let template = ConfigurationStore.shared.configuration.openFileCommand
        guard !template.isEmpty else {
            NSWorkspace.shared.open(url)
            return true
        }
        let arguments = openFileArguments(
            template: template, path: url.path, line: line, column: column)
        guard let executable = arguments.first, executable.hasPrefix("/") else {
            // An absolute path, like every other executable Corta launches
            // (`Spawn`): resolving a bare name would mean consulting a `PATH`
            // that the user's shell, not Corta, controls.
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    /// B07 — the file reference `openFileReferenceInCommand(_:)` opens: the
    /// last one on the last logical line of `record`'s output that has one,
    /// walking backwards. Closest to the end is closest to where a build
    /// tool actually prints "here is the problem," after whatever preamble
    /// came first — a compiler's summary line, a stack trace's innermost
    /// frame, a test runner's failure detail.
    ///
    /// Bounded the same way `FileReferenceDetection.reference(at:in:)`
    /// already is for a single line (P08's "not an unbounded regex pass"
    /// rule) — here bounded in *rows scanned* instead, since this walks many
    /// lines rather than hit-testing one: a multi-thousand-line build log
    /// with no reference at all must not turn opening this menu item into a
    /// linear scan of the whole thing on the main thread.
    func fileReferenceInCommand(_ record: CommandRecord?) -> ResolvedFileReference? {
        guard let reference = detectedReferenceInCommand(record) else { return nil }
        return Self.resolve(reference, directory: session.workingDirectory)
    }

    /// The raw detection half of `fileReferenceInCommand`, before
    /// resolution — the remote path resolves the same reference against the
    /// pane's remote directory instead (`ViewController+RemoteEdit.swift`).
    func detectedReferenceInCommand(_ record: CommandRecord?)
        -> FileReferenceDetection.Reference?
    {
        guard let record, isOperable else { return nil }
        let start = record.outputStartRow ?? record.promptRow + 1
        let grid = session.snapshot()
        let base = grid.scrollback.totalPushed
        let end = record.endRow ?? grid.absoluteRow(ofScreenRow: grid.cursor.row)
        let startDoc = start - base
        var row = end - base - 1
        var rowsScanned = 0
        while row >= startDoc, rowsScanned < Self.maxCommandOutputRowsScanned {
            let line = grid.logicalLine(containing: row)
            rowsScanned += row - line.firstRow + 1
            if let reference = FileReferenceDetection.references(in: line).last {
                return reference
            }
            row = line.firstRow - 1
        }
        return nil
    }

    private static let maxCommandOutputRowsScanned = 2000

    /// Substitutes `{file}`, `{line}` and `{column}` into the configured
    /// command, one argument at a time.
    ///
    /// Split *before* substitution, so a path containing a space becomes one
    /// argument rather than two — the split is of the template the user wrote,
    /// never of the value the child produced.
    ///
    /// Pure and `nonisolated` (B14): the remote-edit flow's tests drive it
    /// off the main actor, and string substitution needs no queue.
    nonisolated static func openFileArguments(
        template: String, path: String, line: Int, column: Int?
    ) -> [String] {
        template.split(whereSeparator: \.isWhitespace).map { part in
            String(part)
                .replacingOccurrences(of: "{file}", with: path)
                .replacingOccurrences(of: "{line}", with: String(line))
                .replacingOccurrences(of: "{column}", with: String(column ?? 1))
        }
    }
}
