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

/// Display-only names. Acceptance sends fixed widget keys, never these strings.
///
/// A report is believed only with the pane's token in front of it
/// (`Terminal.directoryCompletionToken`): the overlay takes Tab, ←/→ and Esc
/// while it shows, and `ESC]133;D` followed by an untokened report in a
/// `cat`ted file or an `ssh` session's output used to show it on demand.
public struct DirectoryCompletion: Equatable, Sendable {
    // periphery:ignore - compared by ==, so a new report re-presents even with the same labels
    public let revision: Int
    public let selectedIndex: Int
    public let candidates: [String]
    public let typedPrefix: String

    public var previewSuffix: String? {
        guard candidates.indices.contains(selectedIndex),
            candidates[selectedIndex].hasPrefix(typedPrefix) else { return nil }
        return String(candidates[selectedIndex].dropFirst(typedPrefix.count))
    }

    public init?(payload: String) {
        let fields = payload.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 2, fields.count <= 23,
            let revision = Int(fields[0]), revision >= 0,
            let selected = Int(fields[1]), selected >= 0 else { return nil }
        let hasPrefix = fields.count > 2 && fields[2].hasPrefix("p=")
        let encodedPrefix = hasPrefix ? String(fields[2].dropFirst(2)) : ""
        guard let prefix = encodedPrefix.removingPercentEncoding, prefix.utf8.count <= 512,
            !prefix.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else { return nil }
        let nameFields = fields.dropFirst(hasPrefix ? 3 : 2)
        guard nameFields.count <= 20 else { return nil }
        var names: [String] = []
        for field in nameFields {
            guard let name = String(field).removingPercentEncoding,
                !name.isEmpty, name.utf8.count <= 512,
                !name.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) })
                else { return nil }
            names.append(name)
        }
        guard names.isEmpty ? selected == 0 : selected < names.count else { return nil }
        typedPrefix = Self.revealed(prefix)
        self.revision = revision
        selectedIndex = selected
        candidates = names.map(Self.revealed)
    }

    /// `payload` without its `token;` field, or nil when the token is not
    /// `expected`.
    static func untokened(_ payload: ArraySlice<UInt8>, expected: [UInt8]) -> ArraySlice<UInt8>? {
        guard !expected.isEmpty, payload.count > expected.count,
            payload.starts(with: expected),
            payload[payload.startIndex + expected.count] == UInt8(ascii: ";") else { return nil }
        return payload.dropFirst(expected.count + 1)
    }

    /// A folder's name is its own, but drawn as the grid would draw it: a
    /// bidi override or a zero-width character shows as U+FFFD, not as
    /// nothing (`SECURITY.md` §2.5).
    private static func revealed(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { ConcealingScalars.contains($0.value) }) else { return text }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            scalars.append(ConcealingScalars.contains(scalar.value) ? "\u{FFFD}" : scalar)
        }
        return String(scalars)
    }
}
