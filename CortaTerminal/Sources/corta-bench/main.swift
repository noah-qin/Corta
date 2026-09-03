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

/// The distribution of a latency sample set, not its average.
///
/// An average is the one statistic a latency measurement should not be
/// reported as. Keypress latency is not normally distributed — it is a tight
/// body with a tail of vsync misses and scheduling hiccups — and the tail is
/// the part a person feels: 45 ms average with a 90 ms p99 is a terminal that
/// stutters once a second while averaging "fine". So every latency number
/// here reports p50, p95, p99 and the maximum, and the average only as a
/// cross-check against the p50.
struct LatencyDistribution {
    let count: Int
    let meanMs: Double
    let p50Ms: Double
    let p95Ms: Double
    let p99Ms: Double
    let maxMs: Double

    /// - Parameter samplesNanoseconds: need not be sorted.
    init?(samplesNanoseconds: [UInt64]) {
        guard !samplesNanoseconds.isEmpty else { return nil }
        let sorted = samplesNanoseconds.sorted()
        func percentile(_ fraction: Double) -> Double {
            // Nearest-rank, the definition that needs no interpolation and
            // cannot report a value no sample actually had.
            let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
            return Double(sorted[min(max(0, rank), sorted.count - 1)]) / 1e6
        }
        count = sorted.count
        meanMs = Double(sorted.reduce(0, +)) / Double(sorted.count) / 1e6
        p50Ms = percentile(0.50)
        p95Ms = percentile(0.95)
        p99Ms = percentile(0.99)
        maxMs = Double(sorted[sorted.count - 1]) / 1e6
    }

    var description: String {
        "p50 \(String(format: "%.3f", p50Ms)) ms / p95 \(String(format: "%.3f", p95Ms)) ms / "
            + "p99 \(String(format: "%.3f", p99Ms)) ms / max \(String(format: "%.3f", maxMs)) ms "
            + "(mean \(String(format: "%.3f", meanMs)) ms, \(count) samples)"
    }
}

func throughput(_ byteCount: Int, elapsedSeconds: Double) -> Double {
    megabytes(UInt64(byteCount)) / elapsedSeconds
}

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

    struct CountingPerformer: ParserPerformer {
        var printableBytes = 0
        mutating func print(_ scalar: UInt32) { printableBytes &+= 1 }
        mutating func printASCII(_ bytes: ArraySlice<UInt8>) { printableBytes &+= bytes.count }
        mutating func execute(_ control: UInt8) {}
    }

    var parser = Parser()
    var counter = CountingPerformer()
    var start = DispatchTime.now()
    parser.parse(corpus, performer: &counter)
    var elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    print(
        "parser-only throughput: \(String(format: "%.1f", throughput(corpus.count, elapsedSeconds: elapsedSeconds))) MiB/s "
            + "(\(counter.printableBytes) printable bytes observed)"
    )

    var gridOnly = Terminal(rows: 50, columns: 200, scrollbackLimit: 0)
    start = DispatchTime.now()
    gridOnly.feed(corpus)
    elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    print(
        "parser + grid throughput: \(String(format: "%.1f", throughput(corpus.count, elapsedSeconds: elapsedSeconds))) MiB/s "
            + "(scrollback disabled)"
    )

    var terminal = Terminal(rows: 50, columns: 200, scrollbackLimit: 10_000)
    start = DispatchTime.now()
    terminal.feed(corpus)
    elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9

    let mibps = throughput(corpus.count, elapsedSeconds: elapsedSeconds)
    print("core feed throughput: \(String(format: "%.1f", mibps)) MiB/s (\(corpus.count) bytes in \(String(format: "%.3f", elapsedSeconds))s)")
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

// MARK: - Keypress -> grid latency (M4, PERFORMANCE.md §1)

/// The software round-trip a keypress causes before there is anything new
/// for the renderer to draw: write to the PTY, the byte comes back, the
/// reader thread parses it and applies it to the grid. Three things this is
/// NOT, stated plainly because it would be easy to overstate this number:
///
/// 1. It is not a full keypress-to-photon measurement. That also needs one
///    vsync period (already bounded by `FrameCPUBaselineTests`, < 4 ms CPU
///    against an 8.3 ms 120 Hz frame) plus real display/compositor latency,
///    which needs a tool like Typometer against actual hardware and cannot
///    come from a headless benchmark.
/// 2. `/bin/cat` is the child so the number isolates PTY + parse + grid
///    write from a particular shell's own processing cost — but the pty
///    replica's default termios has `ICANON`/`ECHO` set, so what comes back
///    is very likely the kernel tty driver's own echo, not `cat` actually
///    reading and rewriting the byte in userspace. Measured this way it is
///    a floor on the round trip, not a ceiling: an interactive shell (zsh's
///    `zle`) turns raw mode and its own echo on instead, which costs a
///    userspace scheduling hop this number does not include.
/// 3. It says nothing about shell-side processing (prompt redraw, syntax
///    highlighting) some shells do per keystroke.
func benchmarkKeypressLatency() {
    let session: TerminalSession
    do {
        session = try TerminalSession(executable: "/bin/cat", size: TerminalSize(rows: 24, columns: 80))
    } catch {
        print("keypress -> grid latency: SKIPPED (could not spawn /bin/cat: \(error))")
        return
    }
    defer { session.stop() }

    // 200 samples cannot support a p99 — the 99th percentile of 200 is the
    // second-largest value, which is one scheduling hiccup away from being
    // noise. 2000 keeps the whole run under a couple of seconds and makes
    // the p99 a number rather than an anecdote.
    let iterations = 2_000
    var samplesNanoseconds: [UInt64] = []
    samplesNanoseconds.reserveCapacity(iterations)

    let semaphore = DispatchSemaphore(value: 0)
    session.onOutput = { semaphore.signal() }

    // Warm up: the first write pays for thread startup and PTY buffering
    // effects a steady-state loop shouldn't be charged for.
    session.write([UInt8(ascii: "a")])
    _ = semaphore.wait(timeout: .now() + 1)

    for i in 0..<iterations {
        // Cycle through a few scalars so the grid write is not a no-op
        // fast path repeating the exact same cell every time.
        let byte = UInt8(ascii: "a") + UInt8(i % 26)
        let start = DispatchTime.now()
        session.write([byte])
        guard semaphore.wait(timeout: .now() + 1) == .success else { continue }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        samplesNanoseconds.append(elapsed)
    }

    guard !samplesNanoseconds.isEmpty else {
        print("keypress -> grid latency: SKIPPED (no samples completed)")
        return
    }
    guard let distribution = LatencyDistribution(samplesNanoseconds: samplesNanoseconds) else {
        print("keypress -> grid latency: SKIPPED (no samples completed)")
        return
    }
    print(
        "keypress -> grid latency: \(distribution.description) "
            + "(write -> PTY echo -> parse -> grid write; excludes vsync + display)")
}

benchmarkParseThroughput()
benchmarkScrollbackMemory()
benchmarkKeypressLatency()

// MARK: - Where the 100k-line memory actually goes (M4 Step 4 footprint)

func diagnoseScrollbackFootprint() {
    var probe = ContiguousArray<Cell>()
    for _ in 0..<120 { probe.append(.blank) }
    let stride = MemoryLayout<Cell>.stride
    let usedBytes = 120 * stride
    let allocatedBytes = probe.capacity * stride
    print(
        "diagnostic: a 120-cell row grown one append at a time has capacity "
            + "\(probe.capacity) (stride \(stride)B) => \(allocatedBytes)B allocated vs "
            + "\(usedBytes)B used (\(allocatedBytes - usedBytes)B slack/row); "
            + "x100k rows => \((allocatedBytes - usedBytes) * 100_000 / 1_048_576)MB slack, "
            + "\(usedBytes * 100_000 / 1_048_576)MB actual cell data, "
            + "\(allocatedBytes * 100_000 / 1_048_576)MB allocated cell storage")
    print("diagnostic: sizeof(Line) = \(MemoryLayout<Line>.stride)B, x100k => \(MemoryLayout<Line>.stride * 100_000 / 1_048_576)MB for the outer array alone")
}

diagnoseScrollbackFootprint()

// MARK: - Reflow cost on a full scrollback (M4.2)

/// `ResizeDebouncer` (100ms) already means a live drag delivers at most one
/// resize roughly every 100ms, not one per pixel — so "stays smooth" means
/// one reflow finishing well inside that window, not inside a frame budget.
func benchmarkReflowCost() {
    var terminal = Terminal(rows: 50, columns: 120, scrollbackLimit: 100_000)
    let line = String(repeating: "the quick brown fox jumps over ", count: 4) + "\r\n"  // wraps at 120
    let lineBytes = Array(line.utf8)
    for _ in 0..<100_000 {
        terminal.feed(lineBytes)
    }

    let start = DispatchTime.now()
    var grid = terminal.grid
    grid.resize(rows: 50, columns: 80)
    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
    print(
        "reflow cost, 100k-line scrollback, 120 -> 80 columns: \(String(format: "%.1f", elapsedMs)) ms "
            + "(one resize call; ResizeDebouncer coalesces a live drag to ~1 call/100ms)")
}

benchmarkReflowCost()

// MARK: - Search cost over a full scrollback (M4.4)

func benchmarkSearchCost() {
    var terminal = Terminal(rows: 50, columns: 120, scrollbackLimit: 100_000)
    let line = "the quick brown fox jumps over the lazy dog\r\n"
    let lineBytes = Array(line.utf8)
    for _ in 0..<100_000 {
        terminal.feed(lineBytes)
    }

    let before = currentResidentBytes()
    let start = DispatchTime.now()
    let matches = Search.find("fox", in: terminal.grid)
    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
    let after = currentResidentBytes()
    print(
        "search cost, 100k-line scrollback, one query: \(String(format: "%.1f", elapsedMs)) ms, "
            + "\(matches.count) matches, resident delta \(String(format: "%.1f", megabytes(after - before))) MB "
            + "(should not be anywhere near a full-scrollback copy)")
}

benchmarkSearchCost()
