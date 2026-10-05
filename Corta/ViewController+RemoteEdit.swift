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
import CortaSFTP
import CortaTerminal

/// `path:line[:column]` references in a remote pane: resolved against the
/// pane's reported remote directory, downloaded to a managed local copy
/// (`RemoteEditStore`/`RemoteEditCoordinator`), and opened at the line.
/// Uploads are the coordinator's explicit step; nothing here writes
/// anywhere but the managed copy.
///
/// Refused: `.remoteUnknown`, `.unknown`, and `~` paths (the remote home
/// isn't knowable).
extension ViewController {
    /// The remote counterpart of `ResolvedFileReference`.
    nonisolated struct ResolvedRemoteReference: Equatable {
        var host: String
        var remotePath: String
        var line: Int
        var column: Int?
        var range: SelectionRange
    }

    /// Resolves against the remote host and directory, or refuses; pure.
    nonisolated static func resolveRemote(
        _ reference: FileReferenceDetection.Reference, state: PaneRemoteState
    ) -> ResolvedRemoteReference? {
        guard case .remote(let host, let directory, _) = state else { return nil }
        let path = reference.path
        guard !path.hasPrefix("~") else { return nil }
        let absolute =
            path.hasPrefix("/") ? path : RemotePath.join(directory, path)
        return ResolvedRemoteReference(
            host: host, remotePath: RemotePath.normalized(absolute),
            line: reference.line, column: reference.column, range: reference.range)
    }

    /// The remote counterpart of `fileReferenceUnder`.
    func remoteFileReferenceUnder(_ event: NSEvent, in terminalView: TerminalView)
        -> ResolvedRemoteReference?
    {
        guard let reference = detectedReferenceUnder(event, in: terminalView) else { return nil }
        return Self.resolveRemote(reference, state: paneRemoteState)
    }

    /// The remote counterpart of `fileReferenceInCommand(_:)`.
    func remoteFileReferenceInCommand(_ record: CommandRecord?) -> ResolvedRemoteReference? {
        guard let reference = detectedReferenceInCommand(record) else { return nil }
        return Self.resolveRemote(reference, state: paneRemoteState)
    }

    /// Downloads or reuses the managed copy and opens it, asynchronously;
    /// failures are toasts in the typed error's wording.
    @discardableResult
    func openRemote(_ reference: ResolvedRemoteReference) -> Bool {
        Task { [weak self] in
            guard let self else { return }
            do {
                let opened = try await RemoteEditCoordinator.shared.open(
                    host: reference.host, remotePath: reference.remotePath,
                    line: reference.line, column: reference.column)
                if !opened {
                    terminalView?.showToast(
                        L10n.text("toast.badOpenFileCommand"), kind: .warning)
                }
            } catch {
                let error = SFTPBrowserModel.sftpError(error)
                // A declined first connection is an answer, not a failure.
                if case .cancelled = error { return }
                terminalView?.showToast(
                    SFTPBrowserModel.errorMessage(error, host: reference.host), kind: .warning)
            }
        }
        return true
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
