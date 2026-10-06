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
import CortaSFTP
import CortaTerminal

/// What a pane's remote side needs from the pane: the session and what
/// spawned it, and a way to start over.
protocol PaneRemoteHost: AnyObject {
    var session: TerminalSession! { get }
    /// What actually spawned — after a fallback, not what was asked for.
    var launchedCommand: (executable: String, arguments: [String])? { get }
    /// The preset the pane was opened with, if any.
    var preset: Preset? { get }
    /// False for a pane whose setup failed.
    var isOperable: Bool { get }
    /// For toasts.
    var terminalView: TerminalView! { get }
    /// Tears the pane's session down and spawns again; `strictRespawn`
    /// reuses the recorded command exactly.
    func rebuildPane(strictRespawn: Bool)
}

/// One pane's remote side: whether the pane is talking to another
/// machine and which, the honest Reconnect that follows a dead connection,
/// `path:line` references resolved on the remote host, and the way into
/// the SFTP browser.
///
/// The host a pane names is the remote shell's OSC 7 report — child
/// output — so nothing here connects anywhere on its own: the browser
/// asks before a first connection to a reported host (`RemoteHostConsent`),
/// and a remote reference opens only a managed local copy.
final class PaneRemote: NSObject, NSMenuItemValidation {
    weak var host: PaneRemoteHost?

    /// Shared by both readers of the state — the title's cached copy and
    /// one-off questions — so they supersede the same report.
    private var reportTracker = PaneRemoteState.ReportTracker()

    init(host: PaneRemoteHost? = nil) {
        self.host = host
    }

    /// A new session: no report has been seen from it.
    func reset() {
        reportTracker = PaneRemoteState.ReportTracker()
    }

    // MARK: - State

    /// Resolved now, paying the `tcgetpgrp`/`proc_name` syscalls, for one-off
    /// questions. The title reads its cached copy (`PaneWindowTitle`),
    /// keeping syscalls off the output path.
    var state: PaneRemoteState {
        guard let host, host.isOperable else { return .local }
        return resolveState()
    }

    /// One fresh read of the pane's remote state — the syscalls, the
    /// spawn record and the stale-report mask together. Both readers come
    /// through here so a report one of them saw the pane local behind is
    /// superseded for the other too.
    func resolveState() -> PaneRemoteState {
        guard let session = host?.session else { return .local }
        return reportTracker.resolve(
            remoteContext: session.remoteContext,
            hasForegroundJob: session.hasForegroundJob,
            foregroundProcessName: session.foregroundProcessName,
            childIsRemoteLauncher: childIsLiveLauncher)
    }

    /// The pane's own child is a live remote launcher, which the foreground
    /// signal can't see. Liveness is `exitStatus`: an exited `ssh` still
    /// showing output is dead, and its report stale.
    var childIsLiveLauncher: Bool {
        guard let host, let launchedCommand = host.launchedCommand,
            PaneRemoteState.isRemoteLauncher(executable: launchedCommand.executable)
        else { return false }
        return host.session != nil && host.session.pty.exitStatus == nil
    }

    // MARK: - Reconnect

    /// What actually spawned, or the preset's command if the spawn failed.
    var reconnectCommand: (executable: String, arguments: [String])? {
        if let launchedCommand = host?.launchedCommand { return launchedCommand }
        guard let shell = host?.preset?.shell else { return nil }
        return (shell, host?.preset?.arguments ?? [])
    }

    /// Only for a remote launcher whose child is gone: a local shell has Try
    /// Again, and a live `ssh` would have to be killed.
    ///
    /// No Corta-side `ControlMaster`: an opaque master process whose lifetime
    /// Corta owns, coupling panes by host. The system `/usr/bin/ssh` already
    /// honours the user's own `Control*` settings, with ssh owning the
    /// lifetime.
    var canReconnect: Bool {
        guard let command = reconnectCommand,
            PaneRemoteState.isRemoteLauncher(executable: command.executable)
        else { return false }
        guard let session = host?.session else { return true }
        return session.pty.exitStatus != nil
    }

    /// Whether the command reattaches a multiplexer (`tmux attach`,
    /// `screen -r`). Copy only: Corta never claims to restore state.
    nonisolated static func reattachesSession(_ arguments: [String]) -> Bool {
        // Words, since `ssh host "tmux attach"` is the same command.
        let words = arguments.flatMap { $0.split(separator: " ").map(String.init) }
        for (index, word) in words.enumerated() {
            let rest = words[(index + 1)...]
            switch word {
            case "tmux":
                if let verb = rest.first(where: { !$0.hasPrefix("-") }),
                    ["attach", "attach-session", "a"].contains(verb)
                { return true }
            case "screen":
                // `-r`, `-x` and combinations reattach.
                if rest.contains(where: { $0.hasPrefix("-r") || $0.hasPrefix("-x") }) {
                    return true
                }
            default:
                continue
            }
        }
        return false
    }

    @objc func reconnectRemote(_ sender: Any?) {
        guard canReconnect else { return }
        host?.rebuildPane(strictRespawn: true)
    }

    /// Never "restored": the process and remote state are gone. A reattach
    /// command gets the credit, attaching to whatever exists now.
    var reconnectNotice: String {
        if let command = reconnectCommand, Self.reattachesSession(command.arguments) {
            return L10n.text("toast.reconnectedReattach")
        }
        return L10n.text("toast.reconnected")
    }

    // MARK: - Remote references

    /// The remote counterpart of `ViewController.ResolvedFileReference`.
    nonisolated struct ResolvedReference: Equatable {
        var host: String
        var remotePath: String
        var line: Int
        var column: Int?
        var range: SelectionRange
    }

    /// Resolves against the remote host and directory, or refuses; pure.
    /// Refused: `.remoteUnknown`, `.unknown`, and `~` paths (the remote home
    /// isn't knowable).
    nonisolated static func resolve(
        _ reference: FileReferenceDetection.Reference, state: PaneRemoteState
    ) -> ResolvedReference? {
        guard case .remote(let host, let directory, _) = state,
            // The host is a remote shell's report; it reaches ssh only if it
            // could have been typed (`RemoteHostName`).
            RemoteHostName.isAcceptable(host)
        else { return nil }
        let path = reference.path
        guard !path.hasPrefix("~") else { return nil }
        let absolute =
            path.hasPrefix("/") ? path : RemotePath.join(directory, path)
        return ResolvedReference(
            host: host, remotePath: RemotePath.normalized(absolute),
            line: reference.line, column: reference.column, range: reference.range)
    }

    /// A detected reference resolved against this pane's state now.
    func resolve(_ reference: FileReferenceDetection.Reference?) -> ResolvedReference? {
        guard let reference else { return nil }
        return Self.resolve(reference, state: state)
    }

    /// Downloads or reuses the managed copy (`RemoteEditStore`,
    /// `RemoteEditCoordinator`) and opens it at the line, asynchronously;
    /// failures are toasts in the typed error's wording. Uploads are the
    /// coordinator's explicit step; nothing here writes anywhere but the
    /// managed copy.
    @discardableResult
    func open(_ reference: ResolvedReference) -> Bool {
        Task { [weak self] in
            guard let self else { return }
            do {
                let opened = try await RemoteEditCoordinator.shared.open(
                    host: reference.host, remotePath: reference.remotePath,
                    line: reference.line, column: reference.column)
                if !opened {
                    host?.terminalView?.showToast(
                        L10n.text("toast.badOpenFileCommand"), kind: .warning)
                }
            } catch {
                let error = SFTPBrowserModel.sftpError(error)
                // A declined first connection is an answer, not a failure.
                if case .cancelled = error { return }
                host?.terminalView?.showToast(
                    SFTPBrowserModel.errorMessage(error, host: reference.host), kind: .warning)
            }
        }
        return true
    }

    // MARK: - Browse Remote Files…

    /// `.remote` knows the host; `.remoteUnknown` asks, since argv and
    /// screen text aren't honest sources. `.local` and `.unknown` get no
    /// offer. Pure, for tests.
    nonisolated static func canBrowseFiles(state: PaneRemoteState) -> Bool {
        switch state {
        case .remote, .remoteUnknown: return true
        case .local, .unknown: return false
        }
    }

    var canBrowseFiles: Bool {
        Self.canBrowseFiles(state: state)
    }

    @objc func browseRemoteFiles(_ sender: Any?) {
        guard host?.isOperable == true else { return }
        let state = state
        guard Self.canBrowseFiles(state: state) else { return }
        SFTPBrowserController.show(for: state)
    }

    // MARK: - Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(reconnectRemote(_:)):
            // Only a dead remote launcher can reconnect.
            return canReconnect
        case #selector(browseRemoteFiles(_:)):
            // Remote panes only (an unknown host asks for one).
            return canBrowseFiles
        default:
            return true
        }
    }
}

/// Remote POSIX path arithmetic on strings only; `standardizingPath`
/// applies local rules.
enum RemotePath {
    nonisolated static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/\(name)" : "\(directory)/\(name)"
    }

    /// Resolves `.`, `..` and repeated separators, so one remote file is one
    /// managed copy.
    nonisolated static func normalized(_ path: String) -> String {
        var segments: [String] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch segment {
            case ".":
                continue
            case "..":
                // `..` at the root stays put, as in POSIX.
                if !segments.isEmpty { segments.removeLast() }
            default:
                segments.append(String(segment))
            }
        }
        return "/" + segments.joined(separator: "/")
    }
}
