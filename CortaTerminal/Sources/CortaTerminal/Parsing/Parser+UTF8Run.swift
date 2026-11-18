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

// MARK: - Whole UTF-8 sequences

extension Parser {
    /// A ground-state run that starts with a non-ASCII byte, printed in one
    /// call: whole ideograph sequences, bytes that are malformed on their own,
    /// or one whole well-formed scalar. Returns where it ended, or nil to
    /// leave the byte to `advance` and the decoder.
    @inline(__always)
    static func printUTF8Run<P: ParserPerformer>(
        _ span: Span<UInt8>, _ bytes: ArraySlice<UInt8>, from offset: Int, performer: inout P
    ) -> Int? {
        let lead = span[offset]
        if lead >= 0xE4, lead <= 0xE9, let end = cjkRunEnd(span, from: offset) {
            // A run of whole ideograph sequences: one call, as for ASCII.
            performer.printCJK(bytes[(bytes.startIndex + offset)..<(bytes.startIndex + end)])
            return end
        }
        if isMalformedAlone(lead) {
            // Bytes no sequence can start from: each is one U+FFFD and leaves
            // the decoder idle, so a run of them is one call.
            var end = offset + 1
            while end < span.count, isMalformedAlone(span[end]) { end += 1 }
            performer.printReplacements(end - offset)
            return end
        }
        if lead >= 0xC2, let (scalar, length) = wholeScalar(span, at: offset) {
            // A complete, well-formed sequence already in this slice: no
            // decoder state to carry, so the parser stays in ground.
            performer.print(scalar)
            return offset + length
        }
        return nil
    }

    /// A stray continuation (also a lone C1), an overlong lead (`C0`, `C1`)
    /// or a byte past U+10FFFF's leads: `UTF8Decoder.start` answers
    /// `.invalid` for each and begins nothing.
    @inline(__always)
    static func isMalformedAlone(_ byte: UInt8) -> Bool {
        (byte >= 0x80 && byte <= 0xC1) || byte >= 0xF5
    }

    /// The scalar and byte length of the two-, three- or four-byte sequence
    /// starting at `offset` when all of its bytes are in `span` and it is
    /// well formed by the rules `UTF8Decoder` applies (no overlong form, no
    /// surrogate, nothing above U+10FFFF). Anything else is nil, which leaves
    /// the lead byte to `advance` and the decoder, so U+FFFD reporting and
    /// split reads are exactly what they were. The caller has checked that
    /// the lead is at least 0xC2.
    @inline(__always)
    static func wholeScalar(_ span: Span<UInt8>, at offset: Int) -> (UInt32, Int)? {
        let lead = span[offset]
        if lead < 0xE0 {
            guard offset + 1 < span.count else { return nil }
            let second = span[offset + 1]
            guard second & 0xC0 == 0x80 else { return nil }
            return (UInt32(lead & 0x1F) << 6 | UInt32(second & 0x3F), 2)
        }
        if lead < 0xF0 {
            guard offset + 2 < span.count else { return nil }
            let second = span[offset + 1], third = span[offset + 2]
            guard second & 0xC0 == 0x80, third & 0xC0 == 0x80,
                lead != 0xE0 || second >= 0xA0, lead != 0xED || second <= 0x9F
            else { return nil }
            return (UInt32(lead & 0x0F) << 12 | UInt32(second & 0x3F) << 6 | UInt32(third & 0x3F), 3)
        }
        guard lead <= 0xF4, offset + 3 < span.count else { return nil }
        let second = span[offset + 1], third = span[offset + 2], fourth = span[offset + 3]
        guard second & 0xC0 == 0x80, third & 0xC0 == 0x80, fourth & 0xC0 == 0x80,
            lead != 0xF0 || second >= 0x90, lead != 0xF4 || second <= 0x8F
        else { return nil }
        let high = UInt32(lead & 0x07) << 18 | UInt32(second & 0x3F) << 12
        return (high | UInt32(third & 0x3F) << 6 | UInt32(fourth & 0x3F), 4)
    }

    /// Where a run of CJK Unified Ideographs (U+4E00...U+9FFF, three bytes
    /// each) starting at `offset` ends, or nil when fewer than two complete
    /// sequences are there. Every scalar of the block is width 2, none
    /// combines, is a control, conceals, or is East Asian Ambiguous, so the
    /// grid can write the run as pairs without asking about each one
    /// (`CJKRunTests` checks the block). A sequence that is cut off, not
    /// well formed or outside the block ends the run; the byte after it goes
    /// the ordinary way.
    @inline(never)
    static func cjkRunEnd(_ span: Span<UInt8>, from offset: Int) -> Int? {
        var end = offset
        while end + 2 < span.count {
            let lead = span[end], second = span[end + 1], third = span[end + 2]
            guard lead >= 0xE4, lead <= 0xE9, second & 0xC0 == 0x80, third & 0xC0 == 0x80,
                lead != 0xE4 || second >= 0xB8
            else { break }
            end += 3
        }
        return end - offset >= 6 ? end : nil
    }
}
