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

import Foundation

/// A directory on *another* machine that this pane's shell reported through
/// OSC 7 — kept beside, never inside, `Terminal.workingDirectory`.
///
/// **Informational only.** Nothing that spawns a local process (new tabs,
/// splits, restore, file-reference resolution) may read it; those read the
/// local-or-nil `workingDirectory`, so a remote path can never become a
/// local `chdir`.
public struct RemoteContext: Sendable, Equatable {
    public enum Provenance: Sendable, Equatable {
        /// The remote shell's own `OSC 7` — the only source that names a host.
        case osc7
        /// A remote launcher (`ssh`, `mosh`) seen in the foreground. No host:
        /// its argv is deliberately not parsed (aliases, `~/.ssh/config`
        /// names and jump hosts would read back wrong).
        case foregroundProcess
        /// The app spawned the launcher itself (an ssh preset) — certain,
        /// not recognised.
        case spawnedLauncher
    }

    /// Lowercased, trailing dot stripped; never resolved or validated — it is
    /// the name the remote chose to send.
    public let host: String

    /// A path on *that* machine; the same path here is a different file.
    public let directory: String

    public let provenance: Provenance

    public let reportedAt: Date

    public init(host: String, directory: String, provenance: Provenance, reportedAt: Date) {
        self.host = host
        self.directory = directory
        self.provenance = provenance
        self.reportedAt = reportedAt
    }
}
