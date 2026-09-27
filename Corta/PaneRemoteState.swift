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

import CortaTerminal
import Foundation

/// Which machine a pane is talking to, composed from independent signals
/// as a testable value:
///
/// - The remote shell's OSC 7 report (`TerminalSession.remoteContext`),
///   the only signal that names a host.
/// - The foreground process (`PTY.foregroundProcessName`): `ssh`/`mosh`
///   means remote; `tmux`/`screen` means it can't be told.
/// - What the pane spawned: an ssh preset's child is the launcher itself,
///   with no foreground job to see.
///
/// Never read from the screen text (hostile, `SECURITY.md` §2) or the
/// launcher's argv (aliases and `~/.ssh/config` names read back wrong).
nonisolated enum PaneRemoteState: Equatable {
    /// A local shell or command owns the terminal; a lingering remote report
    /// is stale without a launcher to emit it.
    case local
    /// A launcher in front, and the far end reported host and directory.
    case remote(host: String, directory: String, provenance: RemoteContext.Provenance)
    /// A launcher in front, but no report: remote, host unknown.
    case remoteUnknown(provenance: RemoteContext.Provenance)
    /// A multiplexer in front, or the name couldn't be read: uncertain, since
    /// even a report may predate the attach.
    case unknown

    /// `proc_name`s that mean remote; `mosh-client` is mosh's local half.
    private static let remoteLaunchers: Set<String> = ["ssh", "mosh", "mosh-client"]

    /// Whether a spawn path is a remote launcher; asked of the spawn, since a
    /// pane spawned as `ssh` has no foreground job.
    static func isRemoteLauncher(executable: String) -> Bool {
        remoteLaunchers.contains((executable as NSString).lastPathComponent.lowercased())
    }

    /// Multiplexers may be attached to a session over ssh; nothing here can
    /// say.
    private static let multiplexers: Set<String> = ["tmux", "screen"]

    /// Composes the signals. `hasForegroundJob` is separate because a nil name
    /// means either "at a prompt" or "unreadable", which must not be
    /// conflated. `childIsRemoteLauncher` covers a pane spawned as the
    /// launcher; pass it only while that child lives.
    static func resolve(
        remoteContext: RemoteContext?, hasForegroundJob: Bool, foregroundProcessName: String?,
        childIsRemoteLauncher: Bool = false
    ) -> PaneRemoteState {
        if childIsRemoteLauncher {
            // The report outranks the spawn: it alone names a host.
            if let remoteContext {
                return .remote(
                    host: remoteContext.host, directory: remoteContext.directory,
                    provenance: remoteContext.provenance)
            }
            return .remoteUnknown(provenance: .spawnedLauncher)
        }
        guard hasForegroundJob else { return .local }
        guard let name = foregroundProcessName?.lowercased() else { return .unknown }
        if remoteLaunchers.contains(name) {
            // The report outranks the process: it alone names a host.
            if let remoteContext {
                return .remote(
                    host: remoteContext.host, directory: remoteContext.directory,
                    provenance: remoteContext.provenance)
            }
            return .remoteUnknown(provenance: .foregroundProcess)
        }
        if multiplexers.contains(name) { return .unknown }
        return .local
    }

    /// Masks a report once the pane has been seen local behind it.
    ///
    /// Reports clear only on a local OSC 7, which stock shells never send. So
    /// after `ssh A` exits, a later `ssh B` that never reports would resolve
    /// to `.remote(A)` — a stale host shown as certain, and the one SFTP would
    /// use. Once seen with the pane local, that exact report reads as none
    /// until a new one arrives. Reset with the session.
    struct ReportTracker: Equatable {
        private(set) var supersededReport: RemoteContext?

        init() {}

        /// `PaneRemoteState.resolve` with the mask applied and advanced.
        mutating func resolve(
            remoteContext: RemoteContext?, hasForegroundJob: Bool,
            foregroundProcessName: String?, childIsRemoteLauncher: Bool = false
        ) -> PaneRemoteState {
            let report = remoteContext == supersededReport ? nil : remoteContext
            let state = PaneRemoteState.resolve(
                remoteContext: report, hasForegroundJob: hasForegroundJob,
                foregroundProcessName: foregroundProcessName,
                childIsRemoteLauncher: childIsRemoteLauncher)
            if case .local = state, let lingering = remoteContext {
                supersededReport = lingering
            }
            return state
        }
    }

    /// The title badge — `⟂ build-box · app`, `⟂ host unknown`,
    /// `⟂ remote?` — or nil when local. Never a guess.
    var titleComponent: String? {
        switch self {
        case .local:
            return nil
        case .remote(let host, let directory, _):
            return "⟂ \(host) · \(Self.abbreviated(directory))"
        case .remoteUnknown:
            return "⟂ \(L10n.text("remote.hostUnknown"))"
        case .unknown:
            return "⟂ \(L10n.text("remote.uncertain"))"
        }
    }

    /// The last component, without the local `~` rule, which means nothing
    /// on another machine.
    private static func abbreviated(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}
