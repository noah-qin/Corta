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

import AppKit
import CortaTerminal

extension PaneCommands {
    // MARK: - Finder and the working directory

    /// `session.workingDirectory` is nil when remote or unreported
    /// (`Performer+OSC.swift`). No outbound drag: it would need a new drag
    /// gesture beside selection dragging; Reveal and Copy Path cover the
    /// need with existing APIs.
    var knownWorkingDirectory: String? {
        guard let host, host.isOperable else { return nil }
        return host.session.workingDirectory
    }

    var hasKnownWorkingDirectory: Bool { knownWorkingDirectory != nil }

    @objc func revealWorkingDirectoryInFinder(_: Any?) {
        guard let directory = knownWorkingDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)])
    }

    /// Copies the path, confirmed by toast.
    @objc func copyWorkingDirectoryPath(_: Any?) {
        guard let directory = knownWorkingDirectory else {
            host?.terminalView?.showToast(L10n.text("toast.noWorkingDirectory"), kind: .warning)
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(directory, forType: .string)
        host?.terminalView?.showToast(L10n.text("toast.copiedWorkingDirectory"))
    }

    /// `cd ..` through the gated `changeDirectory(to:)`. Reads
    /// `shellDirectory`, so a remote pane walks its own directories; spawns and
    /// the project-root search use the local-only `session.workingDirectory`.
    @objc func changeDirectoryToParent(_: Any?) {
        guard let directory = shellDirectory?.path else { return }
        let parent = (directory as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != directory else { return }
        changeDirectory(to: parent)
    }

    /// `cd` to the nearest `.git` ancestor, same gate; no ancestor is
    /// reported, never guessed.
    @objc func changeDirectoryToProjectRoot(_: Any?) {
        guard let directory = knownWorkingDirectory else { return }
        withProjectRoot(of: directory) { commands, root in
            commands.changeDirectory(to: root)
        }
    }

    /// Splits with a new pane rooted at the parent directory.
    @objc func openParentDirectoryInNewPane(_: Any?) {
        guard let directory = knownWorkingDirectory else { return }
        let parent = (directory as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != directory else { return }
        host?.splitController?.splitFocusedPane(orientation: .columns, workingDirectory: parent)
    }

    @objc func openProjectRootInNewPane(_: Any?) {
        guard let directory = knownWorkingDirectory else { return }
        withProjectRoot(of: directory) { commands, root in
            commands.host?.splitController?.splitFocusedPane(
                orientation: .columns, workingDirectory: root)
        }
    }

    /// Finds `directory`'s project root off the main thread — the walk
    /// `stat`s a child-reported path, which can sit on an unreachable
    /// automount — then runs `body` on it, or reports that there is none.
    private func withProjectRoot(
        of directory: String, _ body: @escaping @MainActor (PaneCommands, String) -> Void
    ) {
        Task { [weak self] in
            let root = await Task.detached(priority: .userInitiated) {
                DirectoryHistory.projectRoot(for: directory)
            }.value
            // The lookup can outlast a change of focus; the toast or split
            // would then land on another pane.
            guard let self, let host, !host.didTeardown, host.isFocusedPane else { return }
            guard let root else {
                host.terminalView?.showToast(L10n.text("toast.noProjectRoot"), kind: .warning)
                return
            }
            body(self, root)
        }
    }

    // MARK: - App-initiated `cd`

    /// Whether this pane can safely receive an app-initiated `cd` now:
    ///
    /// - **Pane identity**: a live session (`isOperable`).
    /// - **Remote context**: a remote path is fine for the pane's own remote
    ///   shell. It must never reach a local spawn, which is structural:
    ///   spawns read `session.workingDirectory`, kept local-only by
    ///   `Performer+OSC.swift`, while remote reports live in `remoteContext`.
    /// - **Prompt state**: `hasShellIntegration` and `!isCommandRunning` — a
    ///   busy shell or a TUI must not get prompt input.
    /// - **Existing input**: the cursor is still at `promptEndPosition`, so
    ///   nothing the user typed gets a `cd` spliced into it.
    var canChangeDirectorySafely: Bool {
        guard let host, host.isOperable, let session = host.session,
            session.hasShellIntegration, !session.isCommandRunning
        else {
            return false
        }
        guard let end = session.promptEndPosition else { return false }
        let grid = session.snapshot()
        guard let screenRow = grid.screenRow(ofAbsoluteRow: end.row) else { return false }
        return grid.cursor.row == screenRow && grid.cursor.column == end.column
    }

    /// Where this pane's shell actually is: local when local, the reported
    /// remote directory (with host) when remote, nil when neither is known.
    /// Only for `changeDirectory(to:)`; local spawns and Finder read
    /// `session.workingDirectory`.
    var shellDirectory: (path: String, host: String?)? {
        guard let host else { return nil }
        switch host.remote.state {
        case .remote(let remoteHost, let directory, _):
            return (directory, remoteHost)
        case .local:
            return host.session?.workingDirectory.map { ($0, nil) }
        case .connected(let target, let directory?):
            return (directory, target)
        case .connected, .remoteUnknown, .unknown:
            // Remote without a report, or a multiplexer: the local directory is
            // stale, and sending it to another machine's shell is a leak.
            return nil
        }
    }

    /// Writes `cd '<path>'` and Return under `canChangeDirectorySafely`;
    /// returns whether it did.
    ///
    /// The path began as child-sent OSC 7 text, which `SECURITY.md` §6 says
    /// never to write back. It goes back only as the user's command: sent on
    /// their own action to the shell on the path's machine, quoted for any
    /// shell (`shellQuoted` — fish reads `'\''` differently), and refused
    /// outright if it holds a control character, the one shape another shell
    /// could read as two commands.
    @discardableResult
    func changeDirectory(to path: String) -> Bool {
        guard canChangeDirectorySafely, Self.isSendableDirectoryPath(path),
            let session = host?.session
        else { return false }
        session.write(Array("cd \(Self.shellQuoted(path))\r".utf8))
        return true
    }

    /// Non-empty, with nothing from C0 or C1.
    nonisolated static func isSendableDirectoryPath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.unicodeScalars.contains { scalar in
                scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
            }
    }
}
