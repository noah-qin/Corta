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
    static func forApp(host: String, maximumDownloadBytes: UInt64? = nil) -> SFTPConnection {
        let environment = ChildEnvironment.default()
        // Remote bytes landing on this Mac get Gatekeeper's first-open check.
        var engine = SFTPTransferEngine.Configuration()
        engine.quarantinesDownloads = true
        engine.maximumDownloadBytes = maximumDownloadBytes
        // Every connection to one host claims its remote paths under the
        // same scope, so a browser upload and a remote-edit save to one file
        // take turns instead of sharing its partial.
        engine.destinationScope = host
        if let override = DiagnosticsEnvironment.sftpSSHExecutable() {
            return SFTPConnection(
                host: host, sshExecutable: override, environment: environment,
                engineConfiguration: engine)
        }
        return SFTPConnection(host: host, environment: environment, engineConfiguration: engine)
    }
}
