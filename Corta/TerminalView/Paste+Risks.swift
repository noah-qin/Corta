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
import Darwin
import Foundation

/// What a paste's text might do if a shell read it (`SECURITY.md` §2.3). Safe off
/// the main thread: on a large paste, it runs there.
nonisolated extension Paste {
    enum PasteRisk: String, CaseIterable, Sendable {
        case shellPipe, sudo, recursiveDelete, continuation, concealed, multiline

        var localizationKey: String { "paste.risk." + rawValue }
    }

    /// `needle` occurs in `bytes`.
    private static func contains(_ bytes: UnsafeBufferPointer<UInt8>, _ needle: StaticString) -> Bool {
        guard let base = bytes.baseAddress, bytes.count >= needle.utf8CodeUnitCount else { return false }
        return memmem(base, bytes.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }

    /// `bytes` without each occurrence of `pattern`.
    private static func removing(_ pattern: [UInt8], from bytes: [UInt8]) -> [UInt8] {
        var kept = [UInt8]()
        kept.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == pattern[0], bytes[index...].starts(with: pattern) {
                index += pattern.count
            } else {
                kept.append(bytes[index])
                index += 1
            }
        }
        return kept
    }

    /// What a shell's quoting leaves of the text, as far as these patterns
    /// care: continuation lines joined, one level of backslash escapes taken
    /// off and quotes dropped, so `s\udo` and `s'u'do` read `sudo`. One pass
    /// over bytes: this ran six whole-string replacements, one of them a regex.
    private static func unquoted(_ payload: String) -> [UInt8] {
        var bytes = Array(payload.utf8)
        if bytes.contains(0x5C) {
            for pattern: [UInt8] in [[0x5C, 0x0D, 0x0A], [0x5C, 0x0A], [0x5C, 0x0D]] {
                bytes = removing(pattern, from: bytes)
            }
        }
        var kept = [UInt8]()
        kept.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch byte {
            case 0x27, 0x22:
                continue
            case 0x5C where index < bytes.count && !startsLine(bytes, at: index):
                // The escaped character, whatever it is, and no second look at it.
                kept.append(bytes[index])
                index += 1
            default:
                kept.append(byte)
            }
        }
        return kept
    }

    /// A line terminator starts at `index`: what `.` would not have matched.
    private static func startsLine(_ bytes: [UInt8], at index: Int) -> Bool {
        switch bytes[index] {
        case 0x0A, 0x0D: return true
        case 0xC2: return index + 1 < bytes.count && bytes[index + 1] == 0x85
        case 0xE2:
            return index + 2 < bytes.count && bytes[index + 1] == 0x80
                && (bytes[index + 2] == 0xA8 || bytes[index + 2] == 0xA9)
        default: return false
        }
    }

    /// The unquoted text. Each pattern is tried only if the literal text it
    /// needs is there: on a megabyte of log the regular expressions cost
    /// seconds, and almost none of them could match.
    private struct Unquoted {
        let bytes: [UInt8]
        /// Built only for a pattern that gets to look at it.
        private var text: String { String(decoding: bytes, as: UTF8.self) }

        private func has(_ needle: StaticString) -> Bool {
            bytes.withUnsafeBufferPointer { Paste.contains($0, needle) }
        }

        private func matches(_ pattern: String) -> Bool {
            text.range(of: pattern, options: .regularExpression) != nil
        }

        /// A pipe into a shell, or the same feed without one: `bash <(curl …)`,
        /// `source <(…)`, and `sh -c "$(curl …)"` / `eval "$(wget …)"`, which
        /// run a download.
        var feedsAShell: Bool {
            if has("|"), has("sh"), matches(
                #"\|&?\s*(?:(?:/[^\s;|&]+/)?sudo\s+(?:-[^\s;|&]+\s+)*(?:(?:root|[0-9]+)\s+)?)?"#
                    + #"(?:/[^\s;|&]+/)?(?:sh|bash|zsh|fish|dash|ksh|csh|tcsh)(?=$|[\s;|&])"#) { return true }
            if has("<("), matches(
                #"(?:^|[\s;|&(])(?:/[^\s;|&]+/)?(?:sh|bash|zsh|fish|dash|ksh|csh|tcsh|source|\.)\s+<\("#
            ) { return true }
            guard has("$(") || has("`"), has("curl") || has("wget") || has("fetch") else { return false }
            return matches(
                #"(?:^|[\s;|&(])(?:eval|(?:/[^\s;|&]+/)?(?:sh|bash|zsh|fish|dash|ksh|csh|tcsh)\s+(?:-[^\s;|&]+\s+)*"#
                    + #"-[A-Za-z]*c[A-Za-z]*)\s+(?:\$\(|`)\s*(?:[^)`]*[\s/])?(?:curl|wget|fetch)(?=$|[\s;|&)`])"#)
        }

        var runsSudo: Bool {
            has("sudo") && matches(#"(?:^|[\s;|&()`'"])(?:/[^\s;|&]+/)?sudo(?=$|[\s;|&()`'"])"#)
        }

        /// Options may be combined, separate, long, or interspersed with paths.
        /// Commands without the word are not split into words at all.
        var deletesRecursively: Bool {
            guard has("rm"), has("-") else { return false }
            return bytes.withUnsafeBufferPointer { bytes in
                let separators: Set<UInt8> = [0x3B, 0x7C, 0x26, 0x0A, 0x0D]
                var start = 0
                for end in 0...bytes.count where end == bytes.count || separators.contains(bytes[end]) {
                    defer { start = end + 1 }
                    guard end > start else { continue }
                    let command = UnsafeBufferPointer(rebasing: bytes[start..<end])
                    if Paste.contains(command, "rm"), Paste.contains(command, "-"), Self.isForcedDelete(command) {
                        return true
                    }
                }
                return false
            }
        }

        private static func isForcedDelete(_ command: UnsafeBufferPointer<UInt8>) -> Bool {
            let words = String(decoding: command, as: UTF8.self)
                .split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let index = words.firstIndex(where: { $0 == "rm" || $0.hasSuffix("/rm") }) else { return false }
            let options = words.dropFirst(index + 1).prefix(while: { $0 != "--" }).filter { $0.hasPrefix("-") }
            let recursive = options.contains {
                $0 == "--recursive" || (!$0.hasPrefix("--") && ($0.contains("r") || $0.contains("R")))
            }
            let force = options.contains { $0 == "--force" || (!$0.hasPrefix("--") && $0.contains("f")) }
            return recursive && force
        }
    }

    /// A backslash right before a line break.
    private static func hasContinuation(_ payload: String) -> Bool {
        var payload = payload
        return payload.withUTF8 { bytes in
            guard bytes.count > 1 else { return false }
            for index in 0..<(bytes.count - 1) where bytes[index] == 0x5C {
                if bytes[index + 1] == 0x0A || bytes[index + 1] == 0x0D { return true }
            }
            return false
        }
    }

    /// Conservative, deterministic patterns, not a shell parser. Inspect the
    /// sanitized payload so stripped controls cannot split a dangerous word.
    /// `shouldStop` is asked between steps; what comes back after it says yes
    /// is to be thrown away.
    static func risks(
        in text: String, bracketedPasteEnabled: Bool = true, shouldStop: () -> Bool = { false }
    ) -> [PasteRisk] {
        let payload = sanitized(text)
        let joined = Unquoted(bytes: unquoted(payload))
        var result: [PasteRisk] = []
        if joined.feedsAShell { result.append(.shellPipe) }
        if shouldStop() { return result }
        if joined.runsSudo { result.append(.sudo) }
        if shouldStop() { return result }
        if joined.deletesRecursively { result.append(.recursiveDelete) }
        if hasContinuation(payload) { result.append(.continuation) }
        if text.unicodeScalars.contains(where: { ConcealingScalars.contains($0.value) }) {
            result.append(.concealed)
        }
        if needsWarning(text: payload, bracketedPasteEnabled: bracketedPasteEnabled) {
            result.append(.multiline)
        }
        return result
    }

    static func warningRisks(
        in text: String, bracketedPasteEnabled: Bool, policy: Configuration.PasteWarning,
        shouldStop: () -> Bool = { false }
    ) -> [PasteRisk] {
        guard policy != .off else { return [] }
        var result = risks(in: text, bracketedPasteEnabled: bracketedPasteEnabled, shouldStop: shouldStop)
        if policy == .always, needsWarning(text: text, bracketedPasteEnabled: false),
            !result.contains(.multiline) { result.append(.multiline) }
        return result
    }
}
