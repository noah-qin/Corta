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
import Testing

@testable import Corta

/// Paste (`SECURITY.md` §2.3): pasted text is data, never a command
/// stream — ESC and C0 controls are stripped, and a paste containing a
/// newline warns unless the application enabled bracketed paste.
struct PasteTests {
    @Test func historyRejectsUnbracketedMultilineAndStripsControlSequences() {
        for text in ["safe\necho evil", "safe\recho evil", "safe\r\necho evil"] {
            #expect(Paste.historyBytes(for: text, bracketedPasteEnabled: false) == nil)
            #expect(Paste.historyBytes(for: text, bracketedPasteEnabled: true)
                == Array("\u{1B}[200~\(text)\u{1B}[201~".utf8))
        }
        #expect(Paste.historyBytes(for: "echo 世界", bracketedPasteEnabled: false)
            == Array("echo 世界".utf8))
        #expect(Paste.historyBytes(for: "\u{1B}[201~\u{3}hello", bracketedPasteEnabled: true)
            == Array("\u{1B}[200~[201~hello\u{1B}[201~".utf8))
        #expect(Paste.historyBytes(for: "\u{3}", bracketedPasteEnabled: true) == nil)
    }
    @Test func escapeAndC0ControlsAreStripped() {
        let malicious = "rm -rf ~\u{1B}[2J\u{7}\u{1}\u{1B}[200~echo hi"
        #expect(Paste.sanitized(malicious) == "rm -rf ~[2J[200~echo hi")
    }

    @Test func everyC0ScalarIsStripped() {
        for value: UInt32 in 0..<0x20 {
            guard value != 0x09, value != 0x0A, value != 0x0D else { continue }
            let text = "a\(Unicode.Scalar(value)!)b"
            #expect(Paste.sanitized(text) == "ab", "C0 control U+\(String(value, radix: 16)) must be stripped")
        }
    }

    @Test func deleteAndC1ControlsAreStripped() {
        // DEL would backspace over "echo safe" once it reached the line editor.
        #expect(Paste.sanitized("echo safe\u{7F}\u{7F}\u{7F}\u{7F}\u{7F}\u{7F}\u{7F}\u{7F}\u{7F}rm") == "echo saferm")
        for value: UInt32 in 0x80...0x9F {
            let text = "a\(Unicode.Scalar(value)!)b"
            #expect(Paste.sanitized(text) == "ab", "C1 control U+\(String(value, radix: 16)) must be stripped")
        }
        #expect(Paste.sanitized("café\u{A0}x") == "café\u{A0}x")
    }

    @Test func tabNewlineAndReturnSurvive() {
        #expect(Paste.sanitized("\ta\nb\rc") == "\ta\nb\rc")
    }

    @Test func plainTextAndUnicodePassThrough() {
        #expect(Paste.sanitized("hello 世界 🎉") == "hello 世界 🎉")
    }

    @Test func newlinePasteNeedsWarningOnlyWithoutBracketedPaste() {
        #expect(Paste.needsWarning(text: "ls\nrm -rf ~", bracketedPasteEnabled: false))
        #expect(!Paste.needsWarning(text: "ls\nrm -rf ~", bracketedPasteEnabled: true))
        #expect(!Paste.needsWarning(text: "single line", bracketedPasteEnabled: false))
    }

    @Test func carriageReturnAlsoNeedsWarning() {
        // CR runs the line just like LF does.
        #expect(Paste.needsWarning(text: "ls\rrm -rf ~", bracketedPasteEnabled: false))
        #expect(Paste.needsWarning(text: "ls\r\nrm -rf ~", bracketedPasteEnabled: false))
    }

    @Test func bracketedPasteWrapsIn2004Markers() {
        let bytes = Paste.bytes(for: "ls", bracketedPasteEnabled: true)
        #expect(bytes == Array("\u{1B}[200~ls\u{1B}[201~".utf8))
    }

    @Test func unbracketedPasteIsJustTheText() {
        #expect(Paste.bytes(for: "ls", bracketedPasteEnabled: false) == Array("ls".utf8))
    }

    // MARK: - Chunking

    @Test func emptyInputYieldsNoChunks() {
        #expect(Paste.chunked([]).isEmpty)
    }

    @Test func inputUnderTheLimitIsOneChunk() {
        let bytes = Array("hello".utf8)
        #expect(Paste.chunked(bytes, maxChunkSize: 64) == [bytes])
    }

    @Test func inputIsSplitAtExactChunkBoundaries() {
        let bytes = Array(0..<9).map { UInt8($0) }
        let chunks = Paste.chunked(bytes, maxChunkSize: 3)
        #expect(chunks == [[0, 1, 2], [3, 4, 5], [6, 7, 8]])
    }

    @Test func aRemainderBecomesAShorterFinalChunk() {
        let bytes = Array(0..<8).map { UInt8($0) }
        let chunks = Paste.chunked(bytes, maxChunkSize: 3)
        #expect(chunks == [[0, 1, 2], [3, 4, 5], [6, 7]])
    }

    @Test func chunksConcatenateBackToTheOriginalBytes() {
        let bytes = (0..<500).map { UInt8($0 % 256) }
        let chunks = Paste.chunked(bytes, maxChunkSize: 37)
        #expect(chunks.flatMap { $0 } == bytes)
        #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= 37 })
    }

    @Test func nonPositiveChunkSizeStillTerminates() {
        let bytes = Array("abc".utf8)
        #expect(Paste.chunked(bytes, maxChunkSize: 0) == [bytes])
        #expect(Paste.chunked(bytes, maxChunkSize: -1) == [bytes])
    }

    @Test func onlyABracketedPasteHasAClosingMarker() {
        #expect(Paste.closing(bracketedPasteEnabled: true) == Array("\u{1B}[201~".utf8))
        #expect(Paste.closing(bracketedPasteEnabled: false) == nil)
    }

    /// Ctrl-C cancels a queued paste; nothing else does, so typing during a
    /// paste never throws it away.
    @Test func onlyCtrlCIsAnInterrupt() {
        #expect(Paste.isInterrupt([0x03]))
        #expect(!Paste.isInterrupt([0x61]))
        #expect(!Paste.isInterrupt([0x03, 0x03]))
    }

    /// A cancel lands between chunks, so a chunk must never end inside a
    /// character, and the closing marker must be a chunk of its own.
    @Test func pasteChunksKeepCharactersAndTheClosingMarkerWhole() {
        let text = String(repeating: "中", count: 10)  // 30 bytes of 3-byte scalars
        let chunks = Paste.chunks(for: text, bracketedPasteEnabled: true, trailer: [0x0D], maxChunkSize: 8)
        #expect(chunks.first?.starts(with: Array("\u{1B}[200~".utf8)) == true)
        #expect(chunks.last == Array("\u{1B}[201~".utf8) + [0x0D])
        for chunk in chunks.dropFirst().dropLast() {
            #expect(String(bytes: chunk, encoding: .utf8) != nil, "a chunk cut a character")
        }
        #expect(chunks.flatMap { $0 } == Array("\u{1B}[200~\(text)\u{1B}[201~\r".utf8))
        #expect(Paste.chunks(for: "ab", bracketedPasteEnabled: false) == [Array("ab".utf8)])
    }
}
