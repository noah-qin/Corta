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

nonisolated struct AgentPanePayload {
    let text: String
    let sourceName: String

    // Each field is optional provenance from the source snapshot.
    // swiftlint:disable:next function_parameter_count
    static func make(
        text: String, paneName: String, host: String?, directory: String?,
        command: String?, exitStatus: Int?
    ) -> Self? {
        func field(_ value: String?, limit: Int = 1024) -> String? {
            guard let value else { return nil }
            // Bound the input before normalizing line breaks in a grid-sourced field.
            let singleLine = String(value.unicodeScalars.prefix(limit).map {
                CharacterSet.newlines.contains($0) || $0.value == 9 ? " " : String($0)
            }.joined())
            let cleaned = ProgramText.clean(singleLine, limit: limit)
                .trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty ? nil : cleaned
        }

        var clean = ""
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value == 9 || value == 10
                || (value >= 32 && !(127...159).contains(value) && !ConcealingScalars.contains(value))
            {
                clean.unicodeScalars.append(scalar)
            }
        }
        guard !clean.isEmpty else { return nil }

        let sourceName = field(paneName) ?? "Terminal"
        let parts = [
            "from " + sourceName, field(host).map { "host " + $0 }, field(directory),
            field(command, limit: 200).map { "$ " + $0 }, exitStatus.map { "exit \($0)" },
        ].compactMap { $0 }
        let body = capped(clean)
        var consecutive = 0
        var longest = 2
        for byte in body.utf8 {
            consecutive = byte == 96 ? consecutive + 1 : 0
            longest = max(longest, consecutive)
        }
        let fence = String(repeating: "`", count: longest + 1)
        let separator = body.hasSuffix("\n") ? "" : "\n"
        return Self(
            text: "[\(parts.joined(separator: " · "))]\n\(fence)\n\(body)\(separator)\(fence)",
            sourceName: sourceName)
    }

    private static func capped(_ text: String) -> String {
        let bytes = text.utf8
        guard bytes.count > 32 * 1024 else { return text }
        // Keep complete lines, including their newline. A line longer than
        // either budget may be omitted in its entirety.
        let head = bytes.prefix(8 * 1024).lastIndex(of: 10).map { bytes.index(after: $0) }
            ?? bytes.startIndex
        let tailWindow = bytes.suffix(24 * 1024)
        let tail = bytes[bytes.index(before: tailWindow.startIndex)] == 10
            ? tailWindow.startIndex
            : tailWindow.firstIndex(of: 10).map { bytes.index(after: $0) } ?? bytes.endIndex
        let omitted = bytes[head..<tail]
        let lines = omitted.reduce(0) { $0 + ($1 == 10 ? 1 : 0) } + (omitted.last == 10 ? 0 : 1)
        let lineLabel = lines == 1 ? "line" : "lines"
        return String(decoding: bytes[..<head], as: UTF8.self)
            + "[… \(lines) \(lineLabel) (\(omitted.count) bytes) omitted …]\n"
            + String(decoding: bytes[tail...], as: UTF8.self)
    }
}
