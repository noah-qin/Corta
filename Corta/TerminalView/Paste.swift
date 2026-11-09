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

    /// `chunks(for:bracketedPasteEnabled:)` of a large paste, cut off the
    /// main thread, with the encoding it was cut for: one cut for the other
    /// encoding would send the markers wrongly.
    struct PreparedChunks: Sendable {
        let bracketed: Bool
        let chunks: [[UInt8]]
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
