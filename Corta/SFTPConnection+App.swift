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

/// The one place the app decides which `ssh` binary an SFTP
/// connection spawns.
///
/// Production is always the system client (`SFTPSubprocessChannel
/// .defaultSSHPath`). `CORTA_SFTP_SSH` is a verification hook in the same
/// class as `CORTA_METAL4`: it names an absolute path to run *instead* of
/// `/usr/bin/ssh`, receiving the same argv (`-s -- <host> sftp`), so the
/// real channel, session, engine, browser and remote-edit flow can be driven
/// against a real OpenSSH `sftp-server` on this machine — a script that
/// `exec`s `/usr/libexec/sftp-server` — without a network, a listening sshd
/// or any change to the machine. Read once per launch from the process's
/// own environment (never a config key); a relative value is ignored, since
/// the channel refuses to search `PATH` (`SFTPChannel.swift`).
extension SFTPConnection {
    static func forApp(host: String) -> SFTPConnection {
        if let override = ProcessInfo.processInfo.environment["CORTA_SFTP_SSH"],
            override.hasPrefix("/")
        {
            return SFTPConnection(host: host, sshExecutable: override)
        }
        return SFTPConnection(host: host)
    }
}
