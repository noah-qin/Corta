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

/// Which `ssh` an SFTP connection spawns: the system client, unless
/// `CORTA_SFTP_SSH` names an absolute path to run instead with the same
/// argv — a verification hook (like `CORTA_MAX_DRAWABLES`) for driving the real
/// flow against a local `sftp-server` without a network or sshd. Read once
/// from the environment; relative values are ignored (no `PATH` search,
/// `SFTPChannel.swift`).
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
