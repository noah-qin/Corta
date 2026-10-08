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

import CortaSFTP
import CortaTerminal
import Foundation

/// The fuzz harness for the feed path (`CONFORMANCE.md` §4.3): run hostile
/// input until something crashes, hangs or grows, and assert the §3 caps on
/// every input rather than hoping a sanitizer notices.
///
/// `--target` picks what the mutated bytes are. `terminal` (the default)
/// feeds them as they are. `osc` and `kitty` frame them as one OSC or APC
/// sequence first, so nearly every input reaches a payload handler instead
/// of the ground state; `kitty` also wraps most of them as an `o=z`
/// transmission, which is the inflate path. `sftp` decodes them as one SFTP
/// frame from a hostile server and holds every frame that decodes to
/// surviving a re-encode. Each target has its own corpus directory under
/// `Tests/Fuzz` (`corpus`, `osc`, `kitty`, `sftp`).
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
/// .build/release/corta-fuzz --target sftp --fuzz 200000 --seed 1 Tests/Fuzz/sftp
/// ```
///
/// A small 24×80 grid makes scrollback, reflow and wrapping reachable within
/// the few hundred bytes a fuzzer explores.
private let initialRows = 24
private let initialColumns = 80
private let scrollbackLimit = 64

/// A violated cap traps, which is what the fuzzer reports.
@discardableResult
func fuzzOne(_ bytes: [UInt8]) -> Int32 {
    var terminal = Terminal(
        rows: initialRows, columns: initialColumns, scrollbackLimit: scrollbackLimit)
    var rows = initialRows
    var columns = initialColumns
    // Split at input-derived boundaries: mid-character and mid-sequence
    // splits are where decoder state goes wrong. Some boundaries also
    // resize, from the next two bytes: a reflow runs over whatever the
    // stream left in the grid, and a stream that cannot crash the parser
    // could still leave a row that crashed the next window resize. Derived
    // from the input, so a failure still replays from its file.
    var offset = 0
    while offset < bytes.count {
        let step = 1 + Int(bytes[offset]) % 17
        let end = min(bytes.count, offset + step)
        terminal.feed(bytes[offset..<end])
        if bytes[offset] % 11 == 0, end + 1 < bytes.count {
            rows = 1 + Int(bytes[end]) % 30
            columns = 1 + Int(bytes[end + 1]) % 100
            terminal.resize(rows: rows, columns: columns)
        }
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

/// What the mutated bytes stand for; see the file's doc comment.
enum FuzzTarget: String, CaseIterable {
    case terminal
    case osc
    case kitty
    case sftp
}

/// The OSC codes `Performer.oscDispatch` handles, so a payload reaches a
/// handler rather than the default branch.
private let oscCodes = [
    "0", "2", "4", "5", "7", "8", "10", "11", "12", "52", "104", "105", "133", "134",
]

/// One OSC sequence: the first byte picks the code and the terminator, the
/// rest is the payload as the stream would send it.
func oscStream(_ bytes: [UInt8]) -> [UInt8] {
    guard let first = bytes.first else { return [] }
    let code = oscCodes[Int(first) % oscCodes.count]
    var stream: [UInt8] = [0x1B, 0x5D]
    stream.append(contentsOf: Array(code.utf8))
    stream.append(0x3B)
    stream.append(contentsOf: bytes.dropFirst())
    // BEL and ST both end an OSC.
    if first & 1 == 0 {
        stream.append(0x07)
    } else {
        stream.append(contentsOf: [0x1B, 0x5C])
    }
    return stream
}

/// One Kitty graphics APC sequence. A third of the inputs are the control
/// data and payload as sent; the rest are a compressed transmission whose
/// zlib stream is the input, for RGBA of a declared 4×4 or for PNG.
func kittyStream(_ bytes: [UInt8]) -> [UInt8] {
    guard let first = bytes.first else { return [] }
    let rest = Array(bytes.dropFirst())
    var stream: [UInt8] = [0x1B, 0x5F, 0x47]
    if first % 3 == 0 {
        stream.append(contentsOf: rest)
    } else {
        let format = first % 3 == 1 ? "f=32,s=4,v=4" : "f=100"
        let header = "a=T,i=\(1 + Int(first) % 4),q=\(Int(first) % 3),o=z,\(format);"
        stream.append(contentsOf: Array(header.utf8))
        stream.append(contentsOf: Array(Data(rest).base64EncodedString().utf8))
    }
    stream.append(contentsOf: [0x1B, 0x5C])
    return stream
}

/// One SFTP frame body from a hostile server. Decoding may fail — that is a
/// typed error, and the session ends — but it may not trap, and what does
/// decode must mean the same thing once encoded again.
func fuzzSFTP(_ bytes: [UInt8]) {
    if bytes.count >= 4 {
        let length =
            UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
        _ = try? SFTPCodec.validateFrameLength(length)
    }
    _ = SFTPVolumeInfo(extendedReplyBody: bytes)
    guard let message = try? SFTPCodec.decodeFrame(bytes) else { return }
    let frame = SFTPCodec.encodeFrame(message)
    let again = try? SFTPCodec.decodeFrame(Array(frame.dropFirst(4)))
    precondition(again == message, "a decoded frame did not survive re-encoding (type \(message.type))")
}

func fuzz(_ bytes: [UInt8], target: FuzzTarget) {
    switch target {
    case .terminal: fuzzOne(bytes)
    case .osc: fuzzOne(oscStream(bytes))
    case .kitty: fuzzOne(kittyStream(bytes))
    case .sftp: fuzzSFTP(bytes)
    }
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
var target = FuzzTarget.terminal
var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--fuzz" where index + 1 < arguments.count:
        iterations = Int(arguments[index + 1]) ?? 0
        arguments.removeSubrange(index...(index + 1))
    case "--seed" where index + 1 < arguments.count:
        seed = UInt64(arguments[index + 1]) ?? 1
        arguments.removeSubrange(index...(index + 1))
    case "--target" where index + 1 < arguments.count:
        guard let named = FuzzTarget(rawValue: arguments[index + 1]) else {
            let names = FuzzTarget.allCases.map(\.rawValue).joined(separator: ", ")
            FileHandle.standardError.write(Data("unknown target; one of: \(names)\n".utf8))
            exit(2)
        }
        target = named
        arguments.removeSubrange(index...(index + 1))
    default:
        index += 1
    }
}

let corpus = loadCorpus(from: arguments)
if corpus.isEmpty {
    FileHandle.standardError.write(
        Data(
            "usage: corta-fuzz [--target terminal|osc|kitty|sftp] [--fuzz N] [--seed S] <file-or-directory>...\n"
                .utf8))
    exit(2)
}

if iterations == 0 {
    for (offset, input) in corpus.enumerated() {
        fuzz(input, target: target)
        print("ok \(target.rawValue) corpus[\(offset)] (\(input.count) bytes)")
    }
} else {
    var generator = SplitMix64(seed: seed)
    for iteration in 0..<iterations {
        let input = mutate(corpus[generator.index(below: corpus.count)], using: &generator)
        fuzz(input, target: target)
        if iteration % 10_000 == 0 && iteration > 0 { print("\(iteration) inputs") }
    }
    print("\(iterations) \(target.rawValue) inputs, seed \(seed): no crash, no hang, caps held")
}
