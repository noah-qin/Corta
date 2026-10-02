// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

import Cocoa
import CortaTerminal

/// Following `src/main.rs:42:17` from program output to the file.
///
/// **Local versus remote is the safety argument.** A path names a file on
/// the machine that printed it; opened locally from an ssh pane it would be
/// a different file with the same name. `TerminalSession.workingDirectory`
/// is host-filtered (nil for a remote OSC 7), so such a pane refuses.
///
/// **The URL allowlist is untouched** (`SECURITY.md` §2.4). A reference is
/// never parsed as a URL; the `file:` URL is built by Corta from a path
/// resolved against a local directory and confirmed to be a regular file.
/// The child chooses the path, never the scheme.
extension ViewController {
    /// A reference known to name an existing local file.
    struct ResolvedFileReference: Equatable {
        var url: URL
        var line: Int
        var column: Int?
        var range: SelectionRange
    }

    /// Resolves a reference against a directory, or refuses. Pure, with the
    /// filesystem check injected.
    ///
    /// - Parameter directory: the pane's local working directory. Nil (remote
    ///   or unreported) refuses even absolute paths, which name remote files
    ///   there too.
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
        // Resolves `..`, so the path checked is the path opened. Not a sandbox:
        // the shell can read anything the user can.
        let standardized = (absolute as NSString).standardizingPath
        guard isRegularFile(standardized) else { return nil }
        return ResolvedFileReference(
            url: URL(fileURLWithPath: standardized), line: reference.line,
            column: reference.column, range: reference.range)
    }

    func fileReferenceUnder(_ event: NSEvent, in terminalView: TerminalView)
        -> ResolvedFileReference?
    {
        guard let reference = detectedReferenceUnder(event, in: terminalView) else { return nil }
        return Self.resolve(reference, directory: session.workingDirectory)
    }

    /// Detection before resolution, shared with the remote path
    /// (`ViewController+RemoteEdit.swift`).
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

    /// Opens a local file, at the line if the configured command takes one;
    /// shared by local references and `RemoteEditCoordinator`'s managed
    /// copies. Output-derived files require `open-file-command`: a default
    /// application can execute a .command or .terminal file. Runs via `Process` with
    /// separate arguments, **never a shell**, which would revive the path's
    /// metacharacters (`SECURITY.md` §2.3).
    @discardableResult
    static func openFileAt(url: URL, line: Int, column: Int?, command: String? = nil) -> Bool {
        openFileAt(url: url, line: line, column: column, allowsDefaultApplication: false, command: command)
    }

    /// Remote bytes must go to an explicitly configured editor, never to a
    /// LaunchServices handler that could execute a .command or .terminal file.
    static func openRemoteFileAt(url: URL, line: Int, column: Int?) -> Bool {
        openFileAt(url: url, line: line, column: column, allowsDefaultApplication: false)
    }

    static func openFileAt(
        url: URL, line: Int, column: Int?, allowsDefaultApplication: Bool,
        command: String? = nil
    ) -> Bool {
        let template = command ?? ConfigurationStore.shared.configuration.openFileCommand
        guard !template.isEmpty else {
            guard allowsDefaultApplication else { return false }
            NSWorkspace.shared.open(url)
            return true
        }
        let arguments = openFileArguments(
            template: template, path: url.path, line: line, column: column)
        guard let executable = arguments.first, executable.hasPrefix("/") else {
            // Absolute only: a bare name would resolve through the shell's PATH.
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

    /// The last reference in `record`'s output, walking backwards: closest to
    /// where a build tool says what went wrong. Bounded in rows scanned, so a
    /// huge log without one isn't a full scan on the main thread.
    func fileReferenceInCommand(_ record: CommandRecord?) -> ResolvedFileReference? {
        guard let reference = detectedReferenceInCommand(record) else { return nil }
        return Self.resolve(reference, directory: session.workingDirectory)
    }

    /// Detection before resolution, shared with the remote path.
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

    /// Substitutes `{file}`, `{line}` and `{column}` per argument, splitting the
    /// user's template before substitution so a path with spaces stays one
    /// argument. Pure and `nonisolated`.
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
