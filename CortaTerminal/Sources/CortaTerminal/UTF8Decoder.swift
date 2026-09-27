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

/// Incremental UTF-8: a read can end mid-character, so state lives here.
/// Hostile input (`SECURITY.md` §1) yields U+FFFD, never a trap or growth,
/// following the WHATWG decoder as xterm does: overlongs, surrogates and
/// values past U+10FFFF are rejected, and a byte that cannot continue a
/// sequence restarts one — so a truncated sequence cannot swallow an `ESC`.
/// No `String` (`PERFORMANCE.md` §3).
public struct UTF8Decoder: Sendable {
    /// Two scalars when the byte that ends a malformed sequence is itself one.
    public enum Result: Equatable, Sendable {
        case incomplete
        case scalar(UInt32)
        case invalid
        case invalidThen(UInt32)
        case invalidThenIncomplete
    }

    public static let replacement: UInt32 = 0xFFFD

    private var codepoint: UInt32 = 0
    private var bytesNeeded = 0
    private var bytesSeen = 0
    private var lowerBoundary: UInt8 = 0x80
    private var upperBoundary: UInt8 = 0xBF

    public init() {}

    public var isPending: Bool { bytesNeeded > 0 }

    public mutating func decode(_ byte: UInt8) -> Result {
        guard bytesNeeded > 0 else { return start(byte) }

        guard byte >= lowerBoundary, byte <= upperBoundary else {
            // Malformed: report it and retry the byte as a new start.
            reset()
            switch start(byte) {
            case .scalar(let scalar): return .invalidThen(scalar)
            case .incomplete: return .invalidThenIncomplete
            default: return .invalidThen(Self.replacement)
            }
        }

        // The narrowed first continuation rejects overlongs, surrogates, >U+10FFFF.
        lowerBoundary = 0x80
        upperBoundary = 0xBF
        codepoint = codepoint << 6 | UInt32(byte & 0x3F)
        bytesSeen += 1
        guard bytesSeen == bytesNeeded else { return .incomplete }

        let scalar = codepoint
        reset()
        return .scalar(scalar)
    }

    /// `true`: a partial sequence was dropped; print one U+FFFD.
    public mutating func flush() -> Bool {
        guard bytesNeeded > 0 else { return false }
        reset()
        return true
    }

    private mutating func start(_ byte: UInt8) -> Result {
        switch byte {
        case 0x00...0x7F:
            return .scalar(UInt32(byte))
        case 0xC2...0xDF:
            begin(byte & 0x1F, needed: 1)
        case 0xE0...0xEF:
            begin(byte & 0x0F, needed: 2)
            if byte == 0xE0 { lowerBoundary = 0xA0 }  // no overlong two-byte
            if byte == 0xED { upperBoundary = 0x9F }  // no surrogates
        case 0xF0...0xF4:
            begin(byte & 0x07, needed: 3)
            if byte == 0xF0 { lowerBoundary = 0x90 }  // no overlong three-byte
            if byte == 0xF4 { upperBoundary = 0x8F }  // nothing above U+10FFFF
        default:
            // A stray continuation (also a lone C1), an overlong lead or out of range.
            return .invalid
        }
        return .incomplete
    }

    private mutating func begin(_ bits: UInt8, needed: Int) {
        codepoint = UInt32(bits)
        bytesNeeded = needed
        bytesSeen = 0
        lowerBoundary = 0x80
        upperBoundary = 0xBF
    }

    private mutating func reset() {
        codepoint = 0
        bytesNeeded = 0
        bytesSeen = 0
        lowerBoundary = 0x80
        upperBoundary = 0xBF
    }
}
