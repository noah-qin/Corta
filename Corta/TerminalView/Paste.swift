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

/// Sanitises and wraps pasted text for the child (`SECURITY.md` §2.3: "a
/// paste is data, never a command stream"): strip ESC and other C0, and
/// identify risky shell text and concealed scalars even with bracketed
/// paste, plus newlines without it. `nonisolated` so it is testable.
nonisolated enum Paste {
    /// The ?2004 markers.
    static let bracketStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
    static let bracketEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]

    /// The most a paste may be, in UTF-8 bytes, checked before any of it is
    /// walked: the write queue admits one whole paste however large
    /// (`TerminalSession.maxPendingWriteBytes` pushes back on a child that
    /// stopped reading, not on size), so this is what bounds the pasteboard.
    static let maximumBytes = 64 * 1024 * 1024

    /// Below this a paste is scanned where it was asked for, so it keeps its
    /// place among the keystrokes around it; above, off the main thread.
    static let synchronousScanLimit = 64 * 1024

    /// Strips C0 except tab, LF and CR (newlines are guarded by the warning),
    /// DEL and C1. DEL is a line editor's backspace, so a pasted one erased
    /// text the user had seen and left a different command than the one on
    /// the clipboard; C1 includes CSI and ST, which a program reading 8-bit
    /// controls takes for the end of a bracketed paste. Clean text comes back
    /// without a copy.
    static func sanitized(_ text: String) -> String {
        var text = text
        let filtered: [UInt8]? = text.withUTF8 { bytes in
            var index = 0
            while index < bytes.count, !isStripped(bytes, at: index) { index += 1 }
            guard index < bytes.count else { return nil }
            var kept = [UInt8]()
            kept.reserveCapacity(bytes.count)
            kept.append(contentsOf: bytes[..<index])
            while index < bytes.count {
                if isStripped(bytes, at: index) {
                    // A C1 is two bytes in UTF-8, the first of them `C2`.
                    index += bytes[index] == 0xC2 ? 2 : 1
                } else {
                    kept.append(bytes[index])
                    index += 1
                }
            }
            return kept
        }
        guard let filtered else { return text }
        return String(decoding: filtered, as: UTF8.self)
    }

    /// The byte at `index` starts a control `sanitized` removes.
    @inline(__always)
    private static func isStripped(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Bool {
        let byte = bytes[index]
        switch byte {
        case 0x09, 0x0A, 0x0D: return false
        case 0x00..<0x20, 0x7F: return true
        case 0xC2: return index + 1 < bytes.count && (0x80...0x9F).contains(bytes[index + 1])
        default: return false
        }
    }

    static func containsNewline(_ text: String) -> Bool {
        text.utf8.contains { $0 == 0x0A || $0 == 0x0D }
    }

    /// A newline (LF or CR) without bracketed paste would execute.
    static func needsWarning(text: String, bracketedPasteEnabled: Bool) -> Bool {
        // CRLF is one Swift Character; matching individual Characters misses
        // it. The child receives bytes, so inspect the bytes.
        !bracketedPasteEnabled && containsNewline(text)
    }

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

    /// Conservative, deterministic patterns, not a shell parser. Inspect the
    /// sanitized payload so stripped controls cannot split a dangerous word.
    ///
    /// Each pattern is tried only if the literal text it needs is there: on a
    /// megabyte of log the regular expressions cost seconds, and almost none
    /// of them could match. Safe off the main thread. `shouldStop` is asked
    /// between steps; what comes back after it says yes is to be thrown away.
    static func risks(
        in text: String, bracketedPasteEnabled: Bool = true, shouldStop: () -> Bool = { false }
    ) -> [PasteRisk] {
        let payload = sanitized(text)
        let joinedBytes = unquoted(payload)
        let literals = joinedBytes.withUnsafeBufferPointer { joined in
            (
                pipeToShell: contains(joined, "|") && contains(joined, "sh"),
                processSubstitution: contains(joined, "<("),
                download: (contains(joined, "$(") || contains(joined, "`"))
                    && (contains(joined, "curl") || contains(joined, "wget") || contains(joined, "fetch")),
                sudo: contains(joined, "sudo"),
                remove: contains(joined, "rm") && contains(joined, "-")
            )
        }
        // Built only for a pattern that gets to look at it.
        var joinedText: String?
        func matches(_ pattern: String) -> Bool {
            let joined = joinedText ?? String(decoding: joinedBytes, as: UTF8.self)
            joinedText = joined
            return joined.range(of: pattern, options: .regularExpression) != nil
        }
        var result: [PasteRisk] = []
        // The same feed without a pipe: `bash <(curl …)`, `source <(…)`, and
        // `sh -c "$(curl …)"` / `eval "$(wget …)"`, which run a download.
        if (literals.pipeToShell
            && matches(
                #"\|&?\s*(?:(?:/[^\s;|&]+/)?sudo\s+(?:-[^\s;|&]+\s+)*(?:(?:root|[0-9]+)\s+)?)?"#
                    + #"(?:/[^\s;|&]+/)?(?:sh|bash|zsh|fish|dash|ksh|csh|tcsh)(?=$|[\s;|&])"#))
            || (literals.processSubstitution
                && matches(#"(?:^|[\s;|&(])(?:/[^\s;|&]+/)?(?:sh|bash|zsh|fish|dash|ksh|csh|tcsh|source|\.)\s+<\("#))
            || (literals.download
                && matches(
                    #"(?:^|[\s;|&(])(?:eval|(?:/[^\s;|&]+/)?(?:sh|bash|zsh|fish|dash|ksh|csh|tcsh)\s+(?:-[^\s;|&]+\s+)*"#
                        + #"-[A-Za-z]*c[A-Za-z]*)\s+(?:\$\(|`)\s*(?:[^)`]*[\s/])?(?:curl|wget|fetch)(?=$|[\s;|&)`])"#))
        {
            result.append(.shellPipe)
        }
        if shouldStop() { return result }
        if literals.sudo, matches(#"(?:^|[\s;|&()`'"])(?:/[^\s;|&]+/)?sudo(?=$|[\s;|&()`'"])"#) {
            result.append(.sudo)
        }
        if shouldStop() { return result }
        if literals.remove, containsRecursiveDelete(joinedBytes) {
            result.append(.recursiveDelete)
        }
        var scan = payload
        let continues = scan.withUTF8 { bytes -> Bool in
            guard bytes.count > 1 else { return false }
            for index in 0..<(bytes.count - 1) where bytes[index] == 0x5C {
                if bytes[index + 1] == 0x0A || bytes[index + 1] == 0x0D { return true }
            }
            return false
        }
        if continues { result.append(.continuation) }
        if text.unicodeScalars.contains(where: { ConcealingScalars.contains($0.value) }) {
            result.append(.concealed)
        }
        if needsWarning(text: payload, bracketedPasteEnabled: bracketedPasteEnabled) {
            result.append(.multiline)
        }
        return result
    }

    /// Options may be combined, separate, long, or interspersed with paths.
    /// Commands without the word are not split into words at all.
    private static func containsRecursiveDelete(_ joined: [UInt8]) -> Bool {
        joined.withUnsafeBufferPointer { bytes in
            let separators: Set<UInt8> = [0x3B, 0x7C, 0x26, 0x0A, 0x0D]
            var start = 0
            for end in 0...bytes.count where end == bytes.count || separators.contains(bytes[end]) {
                defer { start = end + 1 }
                guard end > start else { continue }
                let command = UnsafeBufferPointer(rebasing: bytes[start..<end])
                guard contains(command, "rm"), contains(command, "-") else { continue }
                let words = String(decoding: command, as: UTF8.self)
                    .split(whereSeparator: { $0.isWhitespace }).map(String.init)
                guard let index = words.firstIndex(where: { $0 == "rm" || $0.hasSuffix("/rm") }) else { continue }
                let options = words.dropFirst(index + 1).prefix(while: { $0 != "--" }).filter { $0.hasPrefix("-") }
                let recursive = options.contains {
                    $0 == "--recursive" || (!$0.hasPrefix("--") && ($0.contains("r") || $0.contains("R")))
                }
                let force = options.contains { $0 == "--force" || (!$0.hasPrefix("--") && $0.contains("f")) }
                if recursive && force { return true }
            }
            return false
        }
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

    /// What `insertText` may send as typed: nothing a line editor or a
    /// bracketed paste would read as a command. Walks the bytes it was given,
    /// and allocates nothing; plain typing takes this path on every key.
    /// A lone Return or newline is the key, not a commit of text.
    static func isPlainInput(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 1, bytes[0] == 0x0A || bytes[0] == 0x0D { return true }
        var previous: UInt8 = 0
        for byte in bytes {
            if byte < 0x20, byte != 0x09 { return false }
            if byte == 0x7F { return false }
            if previous == 0xC2, (0x80...0x9F).contains(byte) { return false }
            previous = byte
        }
        return true
    }

    /// Never let the preview conceal the very characters it warns about.
    /// A multi-megabyte paste previews its start: the sheet is for reading,
    /// and the risk sentences already cover the whole text.
    static func visiblePreview(_ text: String, limit: Int = previewLimit) -> String {
        var preview = String.UnicodeScalarView()
        var count = 0
        for scalar in text.unicodeScalars {
            guard count < limit else {
                preview.append(contentsOf: "\n…".unicodeScalars)
                break
            }
            count += 1
            if ConcealingScalars.contains(scalar.value) {
                preview.append(
                    contentsOf: ("⟦U+" + String(scalar.value, radix: 16, uppercase: true) + "⟧").unicodeScalars)
            } else {
                preview.append(scalar)
            }
        }
        return String(preview)
    }

    static let previewLimit = 64 * 1024

    /// What ends a paste for the child: the closing marker when bracketed.
    /// A cancelled paste the child started reading is closed with it, or the
    /// shell stays in paste mode (`TerminalSession.write(paste:closing:)`).
    static func closing(bracketedPasteEnabled: Bool) -> [UInt8]? {
        bracketedPasteEnabled ? bracketEnd : nil
    }

    /// Ctrl-C as the pane sends it — the kitty protocol's `disambiguate`
    /// leaves it legacy — and the keystroke that cancels a paste still
    /// queued ahead of it.
    static func isInterrupt(_ bytes: [UInt8]) -> Bool {
        bytes == [0x03]
    }

    /// A paste as the session queues it: the text in chunks that never cut a
    /// UTF-8 character, the opening marker on the first, and the closing
    /// marker — with `trailer`, a Return — as a chunk of its own. A cancel
    /// between chunks then never splits a character or a marker.
    static func chunks(
        for text: String, bracketedPasteEnabled: Bool, trailer: [UInt8] = [],
        maxChunkSize: Int = defaultChunkSize
    ) -> [[UInt8]] {
        var text = text
        var chunks = text.withUTF8 { chunked($0, maxChunkSize: maxChunkSize) }
        if bracketedPasteEnabled {
            if chunks.isEmpty { chunks = [bracketStart] } else { chunks[0] = bracketStart + chunks[0] }
            chunks.append(bracketEnd + trailer)
        } else if !trailer.isEmpty {
            chunks.append(trailer)
        }
        return chunks
    }

    /// Wrapped in the ?2004 markers when bracketed, so it reads as data.
    static func bytes(for text: String, bracketedPasteEnabled: Bool) -> [UInt8] {
        let payload = Array(text.utf8)
        guard bracketedPasteEnabled else { return payload }
        return bracketStart + payload + bracketEnd
    }

    /// Output-derived history is inserted as data; only explicit Run adds
    /// Return. Without bracketed paste, multiline insertion cannot be safe.
    static func historyBytes(for text: String, bracketedPasteEnabled: Bool) -> [UInt8]? {
        let text = sanitized(text)
        guard !text.isEmpty,
            !needsWarning(text: text, bracketedPasteEnabled: bracketedPasteEnabled)
        else { return nil }
        return bytes(for: text, bracketedPasteEnabled: bracketedPasteEnabled)
    }

    /// Write-call size for a wrapped paste; the child sees one stream. Chunks
    /// share `TerminalSession`'s FIFO with keystrokes, so typing mid-paste
    /// waits one chunk. Matches `TerminalSession.readChunkSize`.
    static let defaultChunkSize = 64 * 1024

    /// In-order chunks; empty in, none out; a non-positive size yields one.
    /// A cut lands before a UTF-8 lead byte, never inside a character, unless
    /// a whole chunk is continuation bytes (not UTF-8 anyway).
    static func chunked(_ bytes: [UInt8], maxChunkSize: Int = defaultChunkSize) -> [[UInt8]] {
        bytes.withUnsafeBufferPointer { chunked($0, maxChunkSize: maxChunkSize) }
    }

    private static func chunked(_ bytes: UnsafeBufferPointer<UInt8>, maxChunkSize: Int) -> [[UInt8]] {
        guard !bytes.isEmpty else { return [] }
        guard maxChunkSize > 0 else { return [Array(bytes)] }
        var chunks: [[UInt8]] = []
        chunks.reserveCapacity((bytes.count + maxChunkSize - 1) / maxChunkSize)
        var offset = 0
        while offset < bytes.count {
            var end = min(offset + maxChunkSize, bytes.count)
            var boundary = end
            while boundary > offset, boundary < bytes.count, bytes[boundary] & 0xC0 == 0x80 {
                boundary -= 1
            }
            if boundary > offset { end = boundary }
            chunks.append(Array(bytes[offset..<end]))
            offset = end
        }
        return chunks
    }
}
