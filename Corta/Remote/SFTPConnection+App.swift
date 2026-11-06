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

import CortaSFTP
import CortaTerminal
import Foundation

/// Which `ssh` an SFTP connection spawns: the system client, unless a
/// Debug build's `CORTA_SFTP_SSH` names an executable to run instead with
/// the same argv — a verification hook for driving the real flow against a
/// local `sftp-server` without a network or sshd
/// (`DiagnosticsEnvironment.sftpSSHExecutable`). Either way the child gets
/// the same sanitised environment as a shell (`ChildEnvironment`).
extension SFTPConnection {
    /// `maximumDownloadBytes` bounds each download: remote editing passes
    /// one, since a server choosing what a ⌘-click fetches could otherwise
    /// fill the disk with no progress row to cancel from.
    static func forApp(key: String, maximumDownloadBytes: UInt64? = nil) -> SFTPConnection {
        var environment = ChildEnvironment.default()
        // Remote bytes landing on this Mac get Gatekeeper's first-open check.
        var engine = SFTPTransferEngine.Configuration()
        engine.quarantinesDownloads = true
        engine.maximumDownloadBytes = maximumDownloadBytes
        // `key` (`SSHTarget.key`) carries the user, port and key the
        // connection is made with. Callers have already checked it.
        let target = SSHTarget(key: key) ?? SSHTarget(host: key)
        engine.destinationScope = destinationScope(for: target)
        let arguments = SFTPSubprocessChannel.arguments(host: target.host, options: target.sshOptions)
        // ssh asks for a password, a passphrase or a new host key through
        // Corta (`SSHAskpass`, D27). The grant lives as long as this
        // connection, which holds it through `onSpawn`.
        var onSpawn: (@Sendable (pid_t) -> Void)?
        // Its dialogs name the place, as the browser window's title does.
        if let grant = SSHAskpassBroker.shared.grant(host: target.displayName) {
            environment.merge(grant.environment) { _, granted in granted }
            onSpawn = { pid in grant.admit(pid) }
        }
        return SFTPConnection(
            host: key,
            sshExecutable: DiagnosticsEnvironment.sftpSSHExecutable() ?? SFTPSubprocessChannel.defaultSSHPath,
            arguments: arguments, environment: environment, engineConfiguration: engine,
            onSpawn: onSpawn)
    }

    /// Every connection to one machine claims its remote paths under the same
    /// scope, so a browser upload and a remote-edit save to one file take
    /// turns instead of sharing its partial. The host and port name the
    /// machine; who signs in, and with which key, reach the same files. An
    /// alias and the name it stands for stay two scopes: ssh's configuration
    /// is not read to say otherwise.
    nonisolated static func destinationScope(for target: SSHTarget) -> String {
        target.port.map { "\(target.host):\($0)" } ?? target.host
    }
}

/// How long a connection may take to answer, not counting the time a person
/// is being asked something: typing a password must not be what disconnects
/// them. A question answered starts the time over — ssh is plainly alive, and
/// what it does next is one more trip to the server.
enum ConnectionDeadline {
    /// The same for the browser and for remote editing.
    static let timeout: Duration = .seconds(30)

    /// Returns when the time is up; throws if cancelled first. Time is counted
    /// tick by tick, each at most twice its length: a main thread busy for
    /// a while is no silence from the server, whose answer may be queued
    /// behind this very check.
    static func wait(_ timeout: Duration, isAsking: () -> Bool) async throws {
        let tick = min(timeout, .milliseconds(100))
        var counted = Duration.zero
        var last = SuspendingClock.now
        while counted < timeout {
            try await Task.sleep(for: tick, clock: .suspending)
            let now = SuspendingClock.now
            counted += min(last.duration(to: now), tick * 2)
            last = now
            if isAsking() { counted = .zero }
        }
    }

    /// The failure a deadline ends in: the host did not answer, retryably.
    nonisolated static func failure(after timeout: Duration) -> SFTPError {
        .transport(.hostUnreachable(diagnostics: "no SFTP answer within \(timeout.components.seconds) seconds"))
    }
}
