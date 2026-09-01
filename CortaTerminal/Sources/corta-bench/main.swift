import CortaTerminal
import Darwin
import Dispatch

/// `corta-bench` — measures the numbers `docs/PERFORMANCE.md` §1 sets
/// targets for and `docs/ROADMAP.md` M1.21 asks to be recorded, not
/// estimated. Run release for real numbers:
///
///     swift run -c release corta-bench

func currentResidentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return info.resident_size
}

func megabytes(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }

// MARK: - Parse throughput

// A representative corpus: plain text, SGR colour changes, cursor moves —
// the shape of real shell output (`ls --color`, log lines), not a
// pathological worst case and not a best case of bare ASCII either.
func makeCorpus(targetBytes: Int) -> [UInt8] {
    var text = ""
    text.reserveCapacity(targetBytes + 256)
    var counter = 0
    while text.utf8.count < targetBytes {
        text += "\u{1B}[32mdrwxr-xr-x\u{1B}[0m  \u{1B}[34muser\u{1B}[0m  file-\(counter).log\r\n"
        counter += 1
    }
    return Array(text.utf8)
}

func benchmarkParseThroughput() {
    let corpus = makeCorpus(targetBytes: 64 * 1_048_576)
    var terminal = Terminal(rows: 50, columns: 200, scrollbackLimit: 10_000)

    let start = DispatchTime.now()
    terminal.feed(corpus)
    let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9

    let mbps = megabytes(UInt64(corpus.count)) / elapsedSeconds
    print("parse throughput: \(String(format: "%.1f", mbps)) MB/s (\(corpus.count) bytes in \(String(format: "%.3f", elapsedSeconds))s)")
}

// MARK: - Scrollback memory at 100k lines

func benchmarkScrollbackMemory() {
    let before = currentResidentBytes()
    var terminal = Terminal(rows: 50, columns: 200, scrollbackLimit: 100_000)
    // 100k lines of realistic width so evicted rows aren't free of cost.
    let line = String(repeating: "x", count: 120) + "\r\n"
    let lineBytes = Array(line.utf8)
    for _ in 0..<100_000 {
        terminal.feed(lineBytes)
    }
    let after = currentResidentBytes()
    print(
        "memory @ 100k scrollback lines: \(String(format: "%.1f", megabytes(after - before))) MB "
            + "(resident before \(String(format: "%.1f", megabytes(before))) MB, after \(String(format: "%.1f", megabytes(after))) MB)"
    )
}

benchmarkParseThroughput()
benchmarkScrollbackMemory()
