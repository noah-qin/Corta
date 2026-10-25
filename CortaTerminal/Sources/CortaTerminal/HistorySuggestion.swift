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

/// Display-only zsh history suffix. Acceptance sends a fixed widget key;
/// the shell retains and appends the original text itself.
public struct HistorySuggestion: Equatable, Sendable {
    public let revision: Int
    public let suffix: String

    /// OSC 134's `h;revision;percent-encoded-suffix` report, after its token.
    public init?(payload: String) {
        let fields = payload.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0] == "h",
            let revision = Int(fields[1]), revision >= 0,
            let suffix = String(fields[2]).removingPercentEncoding,
            suffix.utf8.count <= 512,
            !suffix.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) })
        else { return nil }
        self.revision = revision
        self.suffix = DirectoryCompletion.revealed(suffix)
    }
}
