import CortaTerminal
import Foundation

/// M6.11 — the libFuzzer harness `CONFORMANCE.md` §4.3 promised.
///
/// Every byte from the PTY is hostile (`SECURITY.md` §1), and the feed path
/// is where hostile bytes land first. This target exists to run that path
/// against generated input until something crashes, hangs or grows without
/// bound — and to assert the §3 caps on every single input rather than
/// hoping a sanitizer notices.
///
/// **libFuzzer is not available on this platform.** Xcode 26 ships no
/// `libclang_rt.fuzzer_osx.a`, and `swiftc -sanitize=fuzzer` is rejected
/// outright for `arm64-apple-macosx`. The `LLVMFuzzerTestOneInput` entry
/// point below is still here and still correct — a Linux toolchain, or a
/// future Xcode that ships the runtime, drives it with no changes — but the
/// coverage-guided loop cannot run on the machine this is developed on.
///
/// So the harness also carries its own driver, which is what actually runs:
/// a deterministic mutation loop over the checked-in corpus. It has no
/// coverage feedback, so it explores far less per iteration than libFuzzer
/// would; what it does have is a fixed seed, which makes a failure
/// reproducible from the command line that found it, and it asserts the
/// same caps on every input.
///
/// ```sh
/// swift build --package-path CortaTerminal -c release --product corta-fuzz
/// .build/release/corta-fuzz --fuzz 200000 --seed 1 Tests/Fuzz/corpus
/// .build/release/corta-fuzz Tests/Fuzz/corpus/*.bin   # replay only
/// ```
///
/// When libFuzzer is available:
///
/// ```sh
/// swift build --package-path CortaTerminal -c release --product corta-fuzz \
///   -Xswiftc -sanitize=fuzzer,address
/// .build/release/corta-fuzz -max_total_time=60 corpus/
/// ```
///
/// The grid is small on purpose. A 24x80 screen makes the scrollback cap,
/// the reflow path and the wrap flag all reachable within a few hundred
/// bytes of input, which is the size range a fuzzer actually explores.
private let rows = 24
private let columns = 80
private let scrollbackLimit = 64

/// Feeds one input and asserts the caps that must hold no matter what the
/// stream did. A violation traps, which is what the fuzzer reports.
@discardableResult
func fuzzOne(_ bytes: [UInt8]) -> Int32 {
    var terminal = Terminal(rows: rows, columns: columns, scrollbackLimit: scrollbackLimit)
    // Split at arbitrary boundaries: a chunk boundary may fall in the middle
    // of a UTF-8 character or an escape sequence, and the decoder's state
    // machine is exactly where that goes wrong. Deriving the split from the
    // input keeps the run deterministic.
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
    // Side tables are interned and capped; an input that could grow one per
    // cell would be an unbounded allocation.
    precondition(grid.graphemes.count <= GraphemeTable.capacity)
    precondition(grid.hyperlinks.count <= HyperlinkTable.capacity)

    // Query responses are the one path that writes back to the child. The
    // buffer is drained per feed by `TerminalSession`; nothing here drains
    // it, so its size bounds what a single input can queue.
    precondition(
        terminal.takeOutput().count <= 64 * 1024,
        "one input queued an unreasonable amount of response")
    return 0
}

/// libFuzzer's entry point. Present whether or not the binary was built with
/// `-sanitize=fuzzer`; unused in that case.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzerTestOneInput(_ start: UnsafePointer<UInt8>, _ count: Int) -> Int32 {
    fuzzOne(Array(UnsafeBufferPointer(start: start, count: count)))
}

/// A small deterministic PRNG. `SystemRandomNumberGenerator` would make a
/// failing run impossible to reproduce, which is the one thing a fuzz
/// failure has to be.
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

    /// A value in `0..<limit`. `Int(next())` would trap on any draw above
    /// `Int.max` — which is half of them.
    mutating func index(below limit: Int) -> Int {
        limit <= 0 ? 0 : Int(next() % UInt64(limit))
    }
}

/// The mutations a terminal stream is actually broken by: a truncated
/// sequence, a byte flipped inside a parameter, two sequences spliced
/// together. Byte-level noise on its own rarely reaches the parser's
/// interesting states, which is exactly the gap coverage feedback would
/// close.
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
        // A cap on the mutated size, so the loop stays fast enough to run
        // many iterations rather than a few enormous ones.
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
