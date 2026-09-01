import Testing

@testable import CortaTerminal

/// M1.7 — incremental UTF-8 decoding.
///
/// The expectations follow the WHATWG Encoding Standard's UTF-8 decoder
/// (§ "UTF-8 decoder"), which is the behaviour xterm and every other modern
/// terminal implement. RFC 3629 §3 is the normative rule for what is
/// well-formed.
@Suite("UTF-8 decoder")
struct UTF8DecoderTests {
    /// Feeds bytes and collects every scalar produced, replacement scalars
    /// included — what the parser's ground state will do.
    private func scalars(_ bytes: [UInt8]) -> [UInt32] {
        var decoder = UTF8Decoder()
        var output: [UInt32] = []
        for byte in bytes {
            switch decoder.decode(byte) {
            case .incomplete:
                break
            case .scalar(let scalar):
                output.append(scalar)
            case .invalid, .invalidThenIncomplete:
                output.append(UTF8Decoder.replacement)
            case .invalidThen(let scalar):
                output.append(UTF8Decoder.replacement)
                output.append(scalar)
            }
        }
        return output
    }

    @Test("ASCII decodes one byte at a time")
    func asciiDecodes() {
        #expect(scalars([0x41, 0x7F, 0x00]) == [0x41, 0x7F, 0x00])
    }

    @Test("two, three and four byte sequences decode")
    func multiByteSequencesDecode() {
        // U+00E9 é, U+4F60 你, U+1F600 😀.
        #expect(scalars([0xC3, 0xA9]) == [0x00E9])
        #expect(scalars([0xE4, 0xBD, 0xA0]) == [0x4F60])
        #expect(scalars([0xF0, 0x9F, 0x98, 0x80]) == [0x1F600])
    }

    /// A PTY read can end anywhere. This is the case that a decoder written
    /// against a whole buffer gets wrong.
    @Test("a sequence split across reads decodes as one scalar")
    func splitSequencesDecode() {
        var decoder = UTF8Decoder()
        var result = decoder.decode(0xE4)
        #expect(result == .incomplete)
        #expect(decoder.isPending)
        // ... a second PTY read arrives here ...
        result = decoder.decode(0xBD)
        #expect(result == .incomplete)
        result = decoder.decode(0xA0)
        #expect(result == .scalar(0x4F60))
        #expect(!decoder.isPending)
    }

    /// RFC 3629 §3: `C0`/`C1` leads and `E0 80`, `F0 80` forms encode a
    /// value that has a shorter representation. Accepting them lets a filter
    /// that scans for ASCII bytes be bypassed.
    @Test("overlong encodings are rejected")
    func overlongEncodingsAreRejected() {
        // C0 and C1 can never begin a sequence.
        #expect(scalars([0xC0, 0x80]) == [0xFFFD, 0xFFFD])
        #expect(scalars([0xC1, 0xBF]) == [0xFFFD, 0xFFFD])
        // E0 80 80 would be an overlong U+0000..U+07FF.
        #expect(scalars([0xE0, 0x80, 0x80]) == [0xFFFD, 0xFFFD, 0xFFFD])
        // F0 80 80 80 likewise.
        #expect(scalars([0xF0, 0x80, 0x80, 0x80]) == [0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD])
        // The shortest forms of the same boundary values are accepted.
        #expect(scalars([0xE0, 0xA0, 0x80]) == [0x0800])
        #expect(scalars([0xF0, 0x90, 0x80, 0x80]) == [0x10000])
    }

    @Test("surrogates and values above U+10FFFF are rejected")
    func outOfRangeValuesAreRejected() {
        // ED A0 80 is U+D800, a surrogate.
        #expect(scalars([0xED, 0xA0, 0x80]) == [0xFFFD, 0xFFFD, 0xFFFD])
        // ED 9F BF is U+D7FF, the scalar just below, and is fine.
        #expect(scalars([0xED, 0x9F, 0xBF]) == [0xD7FF])
        // F4 90 80 80 is U+110000.
        #expect(scalars([0xF4, 0x90, 0x80, 0x80]) == [0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD])
        // F4 8F BF BF is U+10FFFF, the last scalar.
        #expect(scalars([0xF4, 0x8F, 0xBF, 0xBF]) == [0x10FFFF])
        // F5 and above cannot begin a sequence at all.
        #expect(scalars([0xF5, 0x80]) == [0xFFFD, 0xFFFD])
        #expect(scalars([0xFF]) == [0xFFFD])
    }

    /// The byte that ends a malformed sequence is not consumed by it. If it
    /// were, a truncated CJK character followed by `ESC` would swallow the
    /// escape and the next sequence would be printed as text.
    @Test("a truncated sequence does not consume the byte that ends it")
    func truncatedSequencesDoNotEatTheNextByte() {
        var decoder = UTF8Decoder()
        var result = decoder.decode(0xE4)
        #expect(result == .incomplete)
        result = decoder.decode(0xBD)
        #expect(result == .incomplete)
        result = decoder.decode(0x41)
        #expect(result == .invalidThen(0x41))
        #expect(!decoder.isPending)

        #expect(scalars([0xE4, 0xBD, 0x1B, 0x5B]) == [0xFFFD, 0x1B, 0x5B])
        // And the byte can start a new multi-byte sequence.
        #expect(scalars([0xE4, 0xE4, 0xBD, 0xA0]) == [0xFFFD, 0x4F60])
    }

    /// A lone C1 byte in a UTF-8 stream is not a control character; it is a
    /// continuation byte with nothing to continue.
    @Test("a stray continuation byte is one replacement")
    func strayContinuationBytes() {
        #expect(scalars([0x80]) == [0xFFFD])
        #expect(scalars([0x9B]) == [0xFFFD])
        #expect(scalars([0x41, 0xBF, 0x42]) == [0x41, 0xFFFD, 0x42])
    }

    @Test("flushing reports a dropped partial sequence once")
    func flushReportsAPartialSequence() {
        var decoder = UTF8Decoder()
        var dropped = decoder.flush()
        #expect(!dropped)
        _ = decoder.decode(0xF0)
        dropped = decoder.flush()
        #expect(dropped)
        dropped = decoder.flush()
        #expect(!dropped)
    }

    /// The decoder is fed by a hostile stream and must be total: no trap, no
    /// unbounded state, for any byte in any state.
    @Test("no byte sequence traps or leaves the decoder pending forever")
    func decodingIsTotal() {
        for lead in UInt8.min...UInt8.max {
            for second in UInt8.min...UInt8.max {
                var decoder = UTF8Decoder()
                _ = decoder.decode(lead)
                _ = decoder.decode(second)
                // Four more bytes end any sequence a lead byte can start.
                for _ in 0..<4 { _ = decoder.decode(0x41) }
                #expect(!decoder.isPending)
            }
        }
    }
}
