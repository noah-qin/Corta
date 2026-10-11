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
@testable import CortaTerminal

@Suite struct ParserSIMDTests {
    struct Recorder: ParserPerformer {
        enum Event: Equatable {
            case print(UInt32), execute(UInt8), escape(Intermediates, UInt8)
            case csi(CSISequence), osc([UInt8]), apc([UInt8])
        }
        var events: [Event] = []
        mutating func print(_ scalar: UInt32) { events.append(.print(scalar)) }
        mutating func execute(_ byte: UInt8) { events.append(.execute(byte)) }
        mutating func escapeDispatch(intermediates: Intermediates, final: UInt8) { events.append(.escape(intermediates, final)) }
        mutating func csiDispatch(_ sequence: CSISequence) { events.append(.csi(sequence)) }
        mutating func oscDispatch(_ bytes: ArraySlice<UInt8>) { events.append(.osc(Array(bytes))) }
        mutating func apcDispatch(_ bytes: ArraySlice<UInt8>) { events.append(.apc(Array(bytes))) }
    }
    @Test func vectorPathPreservesStringAndParameterCaps() {
        for bytes in [
            Array("\u{1B}]".utf8) + Array(repeating: 0x61, count: Parser.maxStringLength + 32) + Array("\u{1B}\\after-vector-path-12345".utf8),
            Array("\u{1B}_".utf8) + Array(repeating: 0x61, count: Parser.maxAPCStringLength + 32) + Array("\u{1B}\\after-vector-path-12345".utf8),
            Array("\u{1B}P1;2q".utf8) + Array(repeating: 0x61, count: Parser.maxStringLength + 32) + Array("\u{1B}\\after-vector-path-12345".utf8),
            Array("\u{1B}[".utf8) + Array(repeating: 0x39, count: 10000) + Array("mafter-vector-path-12345".utf8),
            Array("\u{1B}[".utf8) + Array(repeating: 0x3B, count: 10000) + Array("mafter-vector-path-12345".utf8)
        ] {
            var a = Parser(), b = Parser(), x = Recorder(), y = Recorder()
            a.parse(bytes, performer: &x)
            for byte in bytes { b.advance(byte, performer: &y) }
            #expect(x.events == y.events)
            #expect(a.state == b.state)
            #expect(!x.events.contains { if case .osc = $0 { return true }; if case .apc = $0 { return true }; return false })
        }
    }

    @Test func differentialScanner() throws {
        let cases = Int(ProcessInfo.processInfo.environment["CORTA_DIFFERENTIAL_CASES"] ?? "10000") ?? 10000
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fuzz/corpus")
        let corpus = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { !$0.hasDirectoryPath }.map { Array(try Data(contentsOf: $0)) }
        var seed: UInt64 = 0x289
        func random() -> UInt64 {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed
        }
        for iteration in 0..<cases {
            var bytes = iteration < corpus.count ? corpus[iteration] : Array(repeating: UInt8(ascii: "x"), count: Int(random() % 128))
            if iteration >= corpus.count {
                if iteration % 3 == 0, !corpus.isEmpty { bytes = corpus[Int(random() % UInt64(corpus.count))] }
                for _ in 0..<max(1, bytes.count / 8) {
                    if !bytes.isEmpty { bytes[Int(random() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: random()) }
                }
            }
            var fast = Parser(), reference = Parser()
            var a = Recorder(), b = Recorder()
            var terminal = Terminal(rows: 4, columns: 12, scrollbackLimit: 8)
            var scalarTerminal = Terminal(rows: 4, columns: 12, scrollbackLimit: 8)
            var offset = 0
            while offset < bytes.count {
                let end = min(bytes.count, offset + 1 + Int(random() % 33))
                fast.parse(bytes[offset..<end], performer: &a)
                for byte in bytes[offset..<end] { reference.advance(byte, performer: &b) }
                terminal.feed(bytes[offset..<end])
                scalarTerminal.feed(AnySequence(bytes[offset..<end]))
                offset = end
            }
            guard a.events == b.events, fast.state == reference.state,
                  terminal.grid.dump(options: .init(includeScrollback: true)) == scalarTerminal.grid.dump(options: .init(includeScrollback: true)) else {
                Issue.record("differential input \(iteration), seed 0x289, bytes \(bytes)"); return
            }
        }
    }
}
