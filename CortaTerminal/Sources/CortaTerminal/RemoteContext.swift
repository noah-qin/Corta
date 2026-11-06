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

    /// Lowercased, trailing dot stripped, and within the characters
    /// `Performer.isReportableHost` admits; never resolved — it is the name
    /// the remote chose to send.
    public let host: String

    /// A path on *that* machine; the same path here is a different file.
    public let directory: String

    public let provenance: Provenance

    // periphery:ignore - compared by ==: a fresh report of the same place unmasks a superseded one
    public let reportedAt: Date

    public init(host: String, directory: String, provenance: Provenance, reportedAt: Date) {
        self.host = host
        self.directory = directory
        self.provenance = provenance
        self.reportedAt = reportedAt
    }

    /// The most of a host or path a label shows; the value itself is kept whole.
    public static let maximumDisplayedScalars = 255

    /// A reported host or path as the app may show it: the one rule for every
    /// such label. Controls (C0, DEL, C1) and format characters, bidi overrides
    /// among them, become U+FFFD, so a name cannot read as something it is not,
    /// and the length is bounded. `Performer` already refuses most of this on
    /// the way in; this covers what the intake lets through (a path may hold a
    /// format character) and what an older build recorded.
    ///
    /// For display only: never connect to, or navigate by, what this returns.
    public static func displayText(_ text: String) -> String {
        var shown = String.UnicodeScalarView()
        for (index, scalar) in text.unicodeScalars.enumerated() {
            guard index < maximumDisplayedScalars else {
                shown.append("\u{2026}")
                break
            }
            let hidden =
                scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format
                || ConcealingScalars.contains(scalar.value)
            shown.append(hidden ? "\u{FFFD}" : scalar)
        }
        return String(shown)
    }
}
