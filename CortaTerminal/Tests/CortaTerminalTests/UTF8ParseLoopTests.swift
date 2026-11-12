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

import Testing

@testable import CortaTerminal

/// The parse loop decodes a complete, well-formed UTF-8 sequence in place;
/// everything else reaches `UTF8Decoder` through `advance`. Feeding one byte
/// at a time can never take the in-place path (a one-byte slice holds no
/// whole sequence), so it is the reference: a stream fed whole, cut anywhere,
/// or one byte at a time must print the same scalars and leave the same grid.
@Suite("UTF-8 in the parse loop")
struct UTF8ParseLoopTests {
    typealias Recorder = ParserSIMDTests.Recorder

    /// What the parser reports for `bytes` fed as `chunks`: every event, and
    /// the state it is left in.
    private func events(_ bytes: [UInt8], chunks: [Range<Int>]) -> (events: [Recorder.Event], state: Parser.State) {
        var parser = Parser()
        var recorder = Recorder()
        for chunk in chunks { parser.parse(bytes[chunk], performer: &recorder) }
        return (recorder.events, parser.state)
    }

    private func eventsByByte(_ bytes: [UInt8]) -> (events: [Recorder.Event], state: Parser.State) {
        events(bytes, chunks: bytes.indices.map { $0..<($0 + 1) })
    }

    private func grid(_ bytes: [UInt8], chunks: [Range<Int>]) -> String {
        var terminal = Terminal(rows: 4, columns: 12, scrollbackLimit: 8)
        for chunk in chunks { terminal.feed(bytes[chunk]) }
        return terminal.grid.dump(options: .init(includeScrollback: true))
    }

    /// Fed whole, cut at every byte boundary and one byte at a time: the same
    /// events, the same parser state, the same grid.
    private func expectEquivalent(_ bytes: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) {
        let whole = [0..<bytes.count]
        let reference = eventsByByte(bytes)
        let referenceGrid = grid(bytes, chunks: bytes.indices.map { $0..<($0 + 1) })
        let whole1 = events(bytes, chunks: whole)
        #expect(whole1.events == reference.events, "bytes \(bytes)", sourceLocation: sourceLocation)
        #expect(whole1.state == reference.state, "bytes \(bytes)", sourceLocation: sourceLocation)
        #expect(grid(bytes, chunks: whole) == referenceGrid, "bytes \(bytes)", sourceLocation: sourceLocation)
        for cut in 1..<max(1, bytes.count) {
            let chunks = [0..<cut, cut..<bytes.count]
            let split = events(bytes, chunks: chunks)
            #expect(split.events == reference.events, "bytes \(bytes) cut \(cut)", sourceLocation: sourceLocation)
            #expect(split.state == reference.state, "bytes \(bytes) cut \(cut)", sourceLocation: sourceLocation)
            #expect(
                grid(bytes, chunks: chunks) == referenceGrid, "bytes \(bytes) cut \(cut)",
                sourceLocation: sourceLocation)
        }
    }

    @Test("valid two, three and four byte text, with ASCII and controls around it")
    func validText() {
        let samples: [[UInt8]] = [
            Array("é".utf8), Array("┌──┐ café ñ".utf8), Array("你好, 世界".utf8),
            Array("😀🚀👩🏽‍💻".utf8), Array("a\u{7FF}\u{800}\u{FFFF}\u{10000}\u{10FFFF}b".utf8),
            Array("\u{80}\u{7FF}\u{800}\u{D7FF}\u{E000}\u{FFFD}".utf8),
            Array("x\r\né\n\u{1B}[31mü\u{1B}[0m\u{301}\u{200D}\u{202E}z".utf8),
            Array("e\u{301}".utf8) + [0x1B, 0x5B, 0x41] + Array("é".utf8),
        ]
        for sample in samples { expectEquivalent(sample) }
    }

    @Test("every malformed class reaches the decoder unchanged")
    func malformedClasses() {
        let classes: [[UInt8]] = [
            [0x80], [0xBF], [0xC0, 0x80], [0xC1, 0xBF],  // stray continuation, overlong two-byte
            [0xE0, 0x80, 0x80], [0xE0, 0x9F, 0xBF],  // overlong three-byte
            [0xED, 0xA0, 0x80], [0xED, 0xBF, 0xBF],  // surrogates
            [0xF0, 0x80, 0x80, 0x80], [0xF0, 0x8F, 0xBF, 0xBF],  // overlong four-byte
            [0xF4, 0x90, 0x80, 0x80], [0xF4, 0xBF, 0xBF, 0xBF],  // above U+10FFFF
            [0xF5, 0x80, 0x80, 0x80], [0xF8, 0x88, 0x80, 0x80, 0x80], [0xFF], [0xFE, 0xFF],
            [0xC3], [0xE4, 0xBD], [0xF0, 0x9F, 0x98],  // truncated
            [0xC3, 0x41], [0xE4, 0xBD, 0x41], [0xF0, 0x9F, 0x98, 0x41],  // ASCII inside
            [0xC3, 0x1B, 0x5B, 0x41], [0xE4, 0xBD, 0x1B], [0xC3, 0x18], [0xE4, 0x1A],  // controls inside
            [0xC3, 0xC3, 0xA9], [0xE4, 0xE4, 0xBD, 0xA0], [0xF0, 0x9F, 0xF0, 0x9F, 0x98, 0x80],  // lead in lead
            [0xE4, 0xBD, 0xC3, 0xA9], [0xC3, 0xA9, 0xA9], [0xE4, 0xBD, 0xA0, 0xA0, 0xA0],
        ]
        for malformed in classes {
            expectEquivalent(malformed)
            expectEquivalent(Array("ab".utf8) + malformed + Array("é你😀cd".utf8))
            expectEquivalent(Array("é".utf8) + malformed)
            expectEquivalent(malformed + malformed)
        }
    }

    @Test("every two-byte prefix and its edge three- and four-byte neighbours agree with the decoder")
    func exhaustivePrefixes() {
        let edges: [UInt8] = [0x00, 0x1B, 0x41, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xC2, 0xE0, 0xF0, 0xFF]
        for lead in 0x80...0xFF {
            for second in 0...0xFF {
                let pair = [UInt8(lead), UInt8(second), 0x41]
                #expect(
                    events(pair, chunks: [0..<3]).events == eventsByByte(pair).events,
                    "bytes \(pair)")
            }
            for second in edges {
                for third in edges {
                    let triple = [UInt8(lead), second, third, 0x41]
                    #expect(
                        events(triple, chunks: [0..<4]).events == eventsByByte(triple).events,
                        "bytes \(triple)")
                    for fourth in edges {
                        let quad = [UInt8(lead), second, third, fourth, 0x41]
                        #expect(
                            events(quad, chunks: [0..<5]).events == eventsByByte(quad).events,
                            "bytes \(quad)")
                    }
                }
            }
        }
    }

    @Test("a sequence cut at every byte boundary of a slice")
    func cutAtEveryBoundary() {
        for scalar in [0x7FF, 0x800, 0xFFFF, 0x10000, 0x10FFFF] as [UInt32] {
            let bytes = Array(String(Unicode.Scalar(scalar)!).utf8)
            let text = Array("a".utf8) + bytes + Array("b".utf8) + bytes
            expectEquivalent(text)
        }
    }

    @Test("seeded random byte strings")
    func randomBytes() {
        var seed: UInt64 = 0x548
        func next() -> UInt64 {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return seed
        }
        // Weighted toward the bytes that matter to UTF-8: leads, continuations, boundaries.
        let alphabet: [UInt8] = [
            0x41, 0x20, 0x1B, 0x18, 0x0A, 0x5B, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xC1, 0xC2, 0xDF,
            0xE0, 0xE1, 0xEC, 0xED, 0xEE, 0xEF, 0xF0, 0xF1, 0xF3, 0xF4, 0xF5, 0xFF,
        ]
        for iteration in 0..<4000 {
            let count = 1 + Int(next() % 40)
            let bytes = (0..<count).map { _ in
                iteration % 4 == 0 ? UInt8(truncatingIfNeeded: next()) : alphabet[Int(next() % UInt64(alphabet.count))]
            }
            let cut = Int(next() % UInt64(count + 1))
            let reference = eventsByByte(bytes)
            let whole = events(bytes, chunks: [0..<count])
            let split = events(bytes, chunks: [0..<cut, cut..<count])
            #expect(whole.events == reference.events && whole.state == reference.state, "bytes \(bytes)")
            #expect(split.events == reference.events && split.state == reference.state, "bytes \(bytes) cut \(cut)")
            if iteration % 8 == 0 {
                #expect(
                    grid(bytes, chunks: [0..<count]) == grid(bytes, chunks: bytes.indices.map { $0..<($0 + 1) }),
                    "bytes \(bytes)")
            }
        }
    }

    @Test("the parser is back in ground after a whole sequence")
    func groundAfterWholeSequence() {
        var parser = Parser()
        var recorder = Recorder()
        parser.parse(Array("é你😀".utf8), performer: &recorder)
        #expect(parser.state == .ground)
        #expect(recorder.events == [.print(0xE9), .print(0x4F60), .print(0x1F600)])
    }

    @Test("an APC dispatched after a whole sequence still stops the parse")
    func apcStopStillWorks() {
        struct Stopper: ParserPerformer {
            var scalars: [UInt32] = []
            var stops = 0
            var requestsStopAfterAPC: Bool { true }
            mutating func print(_ scalar: UInt32) { scalars.append(scalar) }
            mutating func execute(_ byte: UInt8) {}
            mutating func apcDispatch(_ bytes: ArraySlice<UInt8>) { stops += 1 }
        }
        let bytes = Array("é你".utf8) + Array("\u{1B}_Gi=1\u{1B}\\".utf8) + Array("ü".utf8)
        var parser = Parser()
        var performer = Stopper()
        let consumed = parser.parse(bytes[...], performer: &performer, stoppingAfterAPC: true)
        #expect(consumed == bytes.count - 2)
        #expect(performer.scalars == [0xE9, 0x4F60])
        #expect(performer.stops == 1)
        #expect(parser.state == .ground)
        var rest = parser.parse(bytes[consumed...], performer: &performer, stoppingAfterAPC: true)
        rest += consumed
        #expect(rest == bytes.count)
        #expect(performer.scalars == [0xE9, 0x4F60, 0xFC])
    }
}

/// `displayWidth(of:)` answers the Basic Multilingual Plane from a table.
@Suite("Width table")
struct WidthTableTests {
    /// The width by scanning the generated ranges: no table, no fast path.
    private func scannedWidth(_ value: UInt32) -> Int {
        if value >= 0x20, value < 0x7F { return 1 }
        for range in characterWidthRanges where value >= range.lower && value <= range.upper {
            return Int(range.width)
        }
        return 1
    }

    @Test("the table agrees with the ranges for every scalar U+0000 through U+FFFF")
    func tableAgreesWithRanges() {
        for value in UInt32(0)...0xFFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }  // the surrogates are not scalars
            #expect(displayWidth(of: scalar) == scannedWidth(value), "U+\(String(value, radix: 16, uppercase: true))")
        }
    }

    @Test("supplementary planes still agree with the ranges")
    func supplementaryAgree() {
        // Every 11th scalar of planes 1 to 16, plus both ends of each range.
        var values = Array(stride(from: UInt32(0x10000), through: 0x10FFFF, by: 11))
        for range in characterWidthRanges where range.lower >= 0x10000 {
            values += [range.lower - 1, range.lower, range.upper, range.upper + 1]
        }
        for value in values {
            guard let scalar = Unicode.Scalar(value) else { continue }
            #expect(displayWidth(of: scalar) == scannedWidth(value), "U+\(String(value, radix: 16, uppercase: true))")
        }
    }
}
