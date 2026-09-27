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

/// The fuzz harness for the feed path (`CONFORMANCE.md` §4.3): run hostile
/// input until something crashes, hangs or grows, and assert the §3 caps on
/// every input rather than hoping a sanitizer notices.
///
/// libFuzzer does not link on macOS (no `libclang_rt.fuzzer_osx.a`), so the
/// `LLVMFuzzerTestOneInput` entry point waits for a toolchain that has it,
/// and a seeded mutation driver is what runs — less exploration, but every
/// failure reproduces from its command line.
///
/// ```sh
/// swift build --package-path CortaTerminal -c release --product corta-fuzz
/// .build/release/corta-fuzz --fuzz 200000 --seed 1 Tests/Fuzz/corpus
/// .build/release/corta-fuzz Tests/Fuzz/corpus/*.bin   # replay only
/// ```
///
/// A small 24×80 grid makes scrollback, reflow and wrapping reachable within
/// the few hundred bytes a fuzzer explores.
private let rows = 24
private let columns = 80
private let scrollbackLimit = 64

/// A violated cap traps, which is what the fuzzer reports.
@discardableResult
func fuzzOne(_ bytes: [UInt8]) -> Int32 {
    var terminal = Terminal(rows: rows, columns: columns, scrollbackLimit: scrollbackLimit)
    // Split at input-derived boundaries: mid-character and mid-sequence
    // splits are where decoder state goes wrong.
    var offset = 0
    while offset < bytes.count {
        let step = 1 + Int(bytes[offset]) % 17
        let end = min(bytes.count, offset + step)
        terminal.feed(bytes[offset..<end])
        offset = end
    }

    let grid = terminal.grid

    // `SECURITY.md` §3 — the caps, checked on every input.
    precondition(grid.rows == rows, "the grid must not resize itself")
    precondition(grid.columns == columns, "the grid must not resize itself")
    precondition(
        grid.scrollback.count <= scrollbackLimit,
        "scrollback exceeded its ring limit: \(grid.scrollback.count)")
    precondition(
        grid.cursor.row >= 0 && grid.cursor.row < rows,
        "cursor row escaped the screen: \(grid.cursor.row)")
    precondition(
        grid.cursor.column >= 0 && grid.cursor.column <= columns,
        "cursor column escaped the screen: \(grid.cursor.column)")
    for row in 0..<rows {
        precondition(
            grid.line(row).count <= columns,
            "row \(row) grew past the screen width: \(grid.line(row).count)")
    }
    precondition(grid.graphemes.count <= GraphemeTable.capacity)
    precondition(grid.hyperlinks.count <= HyperlinkTable.capacity)

    // The one path back to the child; undrained here, so its size bounds
    // what one input can queue.
    precondition(
        terminal.takeOutput().count <= 64 * 1024,
        "one input queued an unreasonable amount of response")
    return 0
}

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzerTestOneInput(_ start: UnsafePointer<UInt8>, _ count: Int) -> Int32 {
    fuzzOne(Array(UnsafeBufferPointer(start: start, count: count)))
}

/// Deterministic: a fuzz failure must reproduce.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// `Int(next())` would trap on half of all draws.
    mutating func index(below limit: Int) -> Int {
        limit <= 0 ? 0 : Int(next() % UInt64(limit))
    }
}

/// Truncations, flipped parameter bytes, spliced sequences — what breaks
/// a stream; byte noise alone rarely reaches the parser's states.
func mutate(_ input: [UInt8], using generator: inout SplitMix64) -> [UInt8] {
    var bytes = input
    let operations = 1 + Int(generator.next() % 4)
    for _ in 0..<operations {
        guard !bytes.isEmpty else { break }
        switch generator.next() % 5 {
        case 0:  // flip a byte
            bytes[generator.index(below: bytes.count)] = UInt8(generator.next() % 256)
        case 1:  // truncate
            bytes.removeLast(min(bytes.count, 1 + Int(generator.next() % 16)))
        case 2:  // insert a control byte where the parser has to notice it
            let interesting: [UInt8] = [0x1B, 0x5B, 0x5D, 0x3B, 0x07, 0x00, 0x9C, 0xC0, 0xFF]
            bytes.insert(
                interesting[generator.index(below: interesting.count)],
                at: generator.index(below: bytes.count + 1))
        case 3:  // duplicate a run
            let start = generator.index(below: bytes.count)
            let length = min(bytes.count - start, 1 + Int(generator.next() % 32))
            bytes.insert(contentsOf: bytes[start..<(start + length)], at: start)
        default:  // splice with itself, reversed — cheap way to make a
            // sequence start inside another one
            bytes.append(contentsOf: bytes.reversed().prefix(Int(generator.next() % 64)))
        }
        // Many small iterations beat a few enormous ones.
        if bytes.count > 64 * 1024 { bytes.removeLast(bytes.count - 64 * 1024) }
    }
    return bytes
}

func loadCorpus(from paths: [String]) -> [[UInt8]] {
    var corpus: [[UInt8]] = []
    let manager = FileManager.default
    for path in paths {
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
            continue
        }
        if isDirectory.boolValue {
            let names = (try? manager.contentsOfDirectory(atPath: path)) ?? []
            corpus += loadCorpus(from: names.sorted().map { path + "/" + $0 })
        } else if let data = manager.contents(atPath: path) {
            corpus.append(Array(data))
        }
    }
    return corpus
}

// The driver. `--fuzz N` mutates; anything else replays the named files.
var arguments = Array(CommandLine.arguments.dropFirst())
var iterations = 0
var seed: UInt64 = 1
var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--fuzz" where index + 1 < arguments.count:
        iterations = Int(arguments[index + 1]) ?? 0
        arguments.removeSubrange(index...(index + 1))
    case "--seed" where index + 1 < arguments.count:
        seed = UInt64(arguments[index + 1]) ?? 1
        arguments.removeSubrange(index...(index + 1))
    default:
        index += 1
    }
}

let corpus = loadCorpus(from: arguments)
if corpus.isEmpty {
    FileHandle.standardError.write(
        Data("usage: corta-fuzz [--fuzz N] [--seed S] <file-or-directory>...\n".utf8))
    exit(2)
}

if iterations == 0 {
    for (offset, input) in corpus.enumerated() {
        fuzzOne(input)
        print("ok corpus[\(offset)] (\(input.count) bytes)")
    }
} else {
    var generator = SplitMix64(seed: seed)
    for iteration in 0..<iterations {
        let input = mutate(corpus[generator.index(below: corpus.count)], using: &generator)
        fuzzOne(input)
        if iteration % 10_000 == 0 && iteration > 0 { print("\(iteration) inputs") }
    }
    print("\(iterations) inputs, seed \(seed): no crash, no hang, caps held")
}
