import CortaTerminal
import Darwin
import Dispatch
import Foundation
import Synchronization

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
    var submitted = 0
    var timedOut = 0
    var consecutiveTimeouts = 0
    var aborted = false

    // Request/completion correlation (E06). `onOutput` carries no payload,
    // so a semaphore signal alone cannot say *which* write produced it: a
    // signal from a timed-out write arriving late would be consumed by the
    // next write's wait and recorded as that write's near-zero "latency".
    // The completion counter fixes attribution — a round trip is recorded
    // only once the counter has advanced past the value snapshot at
    // submission, so a stale signal can never stand in for a request's own
    // echo. Timed-out requests are counted, never sampled.
    let completedOutputs = Mutex(0)
    let semaphore = DispatchSemaphore(value: 0)
    session.onOutput = {
        completedOutputs.withLock { $0 += 1 }
        semaphore.signal()
    }
    // Configure-before-start: the reader thread only begins draining the
    // PTY here, after `onOutput` is installed.
    session.start()

    /// Waits until the completion counter reaches `target` or `timeout`
    /// elapses. The semaphore only ever paces the recheck; the counter is
    /// the authority on which requests have completed.
    func awaitCompletion(target: Int, timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + .nanoseconds(Int(timeout * 1e9))
        while completedOutputs.withLock({ $0 }) < target {
            guard semaphore.wait(timeout: deadline) == .success else { return false }
        }
        return true
    }

    // Warm up: the first write pays for thread startup and PTY buffering
    // effects a steady-state loop shouldn't be charged for.
    let warmupTarget = completedOutputs.withLock { $0 } + 1
    session.write([UInt8(ascii: "a")])
    _ = awaitCompletion(target: warmupTarget, timeout: 1)

    for i in 0..<iterations {
        // Cycle through a few scalars so the grid write is not a no-op
        // fast path repeating the exact same cell every time.
        let byte = UInt8(ascii: "a") + UInt8(i % 26)
        let target = completedOutputs.withLock { $0 } + 1
        let start = DispatchTime.now()
        session.write([byte])
        submitted += 1
        if awaitCompletion(target: target, timeout: 1) {
            let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            samplesNanoseconds.append(elapsed)
            consecutiveTimeouts = 0
            continue
        }
        timedOut += 1
        consecutiveTimeouts += 1
        // Resync: give the outstanding echo a grace window to land, so the
        // next request's submission snapshot already contains it and it
        // cannot be attributed to that request. A genuinely lost echo needs
        // no handling — every target is recomputed from the live counter.
        let drainedTarget = completedOutputs.withLock { $0 } + 1
        _ = awaitCompletion(target: drainedTarget, timeout: 0.2)
        // Eight consecutive 1.2 s round-trip failures means the session or
        // the PTY is wedged, not slow; stop rather than sit through the
        // remaining iterations and report what was measured so far.
        if consecutiveTimeouts >= 8 {
            aborted = true
            break
        }
    }

    let completed = samplesNanoseconds.count
    let counts = "\(completed) completed / \(submitted) submitted / \(timedOut) timed out"
    if aborted {
        print(
            "keypress -> grid latency: ABORTED after \(submitted) submissions "
                + "(\(counts); 8 consecutive timeouts — session or PTY unresponsive)")
    }
    guard let distribution = LatencyDistribution(samplesNanoseconds: samplesNanoseconds) else {
        print("keypress -> grid latency: NO DATA (\(counts))")
        return
    }
    print(
        "keypress -> grid latency: \(distribution.description) "
            + "[\(counts); timed-out samples excluded from the percentiles] "
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

/// `ResizeDebouncer` is trailing-only: a drag in continuous motion delivers
/// nothing until the stream pauses for 100ms or ends, so "stays smooth"
/// means one reflow after the gesture, not one inside a frame budget. The
/// throttle alternative is measured head-to-head in
/// `benchmarkResizeStrategies` below (P03).
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

// MARK: - Resize delivery strategies (P03)

/// What a live window drag costs the core under the two delivery policies
/// P03 compares, run against a real session — real PTY, real `resizeQueue`
/// coalescing, real reflow — with a scripted drag: distinct column sizes
/// 120 -> 80, three 8 ms mouse-motion events each (consecutive duplicates
/// are dropped at the source, the same dedup `resizeSessionToFitView`
/// applies via `lastRequestedSize`):
///
/// - `trailing` delivers only the final size when the drag ends — what
///   `ResizeDebouncer` plus the `endLiveResize` flush do today;
/// - `throttle` delivers the first size immediately, then the latest size
///   at most once per interval while the drag continues, plus the final
///   size at the end.
///
/// Reported per policy: sizes handed to `resize(to:)`, reflows actually
/// applied (each applied resize block raises `onOutput`, and the child is
/// quiet during the drag, so the counter delta counts exactly those — each
/// one is also one `SIGWINCH`, i.e. one full-screen redraw for a TUI
/// child), and wall time from the first drag event until the grid shows
/// the final size.
struct ResizeStrategyResult {
    var deliveries = 0
    var appliedReflows = 0
    var wallMs = 0.0
}

func awaitGridColumns(_ session: TerminalSession, _ columns: Int, timeout: TimeInterval) -> Bool {
    let deadline = DispatchTime.now() + .nanoseconds(Int(timeout * 1e9))
    while DispatchTime.now() < deadline {
        if session.snapshot().columns == columns { return true }
        usleep(5_000)
    }
    return session.snapshot().columns == columns
}

/// Waits until the scrollback has stopped growing for a full 100 ms — the
/// child has finished echoing the fill and the drag's `onOutput` delta will
/// count resizes only.
func awaitQuiet(_ session: TerminalSession) {
    var last = -1
    while true {
        let pushed = session.snapshot().scrollback.totalPushed
        if pushed == last { return }
        last = pushed
        usleep(100_000)
    }
}

func runSimulatedDrag(
    _ session: TerminalSession,
    applied: borrowing Mutex<Int>,
    throttleInterval: TimeInterval?
) -> ResizeStrategyResult {
    var result = ResizeStrategyResult()
    let baseline = applied.withLock { $0 }
    let start = DispatchTime.now()
    var lastDelivery = start
    for columns in stride(from: 120, through: 80, by: -1) {
        let size = TerminalSize(rows: 50, columns: UInt16(columns))
        for event in 0..<3 {
            if let throttleInterval {
                let now = DispatchTime.now()
                let leadingEdge = columns == 120 && event == 0
                if leadingEdge
                    || Double(now.uptimeNanoseconds - lastDelivery.uptimeNanoseconds) / 1e9
                        >= throttleInterval
                {
                    session.resize(to: size)
                    result.deliveries += 1
                    lastDelivery = now
                }
            }
            usleep(8_000)
        }
    }
    // Drag end: both policies deliver the final size (`endLiveResize` flush).
    session.resize(to: TerminalSize(rows: 50, columns: 80))
    result.deliveries += 1
    if !awaitGridColumns(session, 80, timeout: 30) {
        print("  warning: final size not on the grid within 30s")
    }
    result.wallMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
    // The resize block raises `onOutput` *after* committing the grid, so the
    // count lags the column check by a hop; the final delivery always
    // applies, and its `onOutput` is the last one the drag can produce
    // (the queue is serial and the child stays quiet).
    let deadline = DispatchTime.now() + .seconds(30)
    while applied.withLock({ $0 }) == baseline, DispatchTime.now() < deadline {
        usleep(5_000)
    }
    result.appliedReflows = applied.withLock { $0 } - baseline
    return result
}

func benchmarkResizeStrategies() {
    let session: TerminalSession
    do {
        session = try TerminalSession(
            executable: "/bin/cat",
            size: TerminalSize(rows: 50, columns: 120),
            scrollbackLimit: 100_000
        )
    } catch {
        print("resize strategies: SKIPPED (could not spawn /bin/cat: \(error))")
        return
    }
    defer { session.stop() }
    let applied = Mutex(0)
    session.onOutput = { applied.withLock { $0 += 1 } }
    session.start()

    func report(_ label: String, _ result: ResizeStrategyResult) {
        print(
            "  \(label): \(result.deliveries) sizes delivered, "
                + "\(result.appliedReflows) reflows applied "
                + "(\(max(0, result.appliedReflows - 1)) stale SIGWINCHs), "
                + "final size on grid after \(String(format: "%.0f", result.wallMs)) ms"
        )
    }

    func dragPair(_ label: String) {
        // Both policies start from the same 120-column state.
        session.resize(to: TerminalSize(rows: 50, columns: 120))
        _ = awaitGridColumns(session, 120, timeout: 30)
        awaitQuiet(session)
        report("\(label), trailing-only", runSimulatedDrag(session, applied: applied, throttleInterval: nil))
        session.resize(to: TerminalSize(rows: 50, columns: 120))
        _ = awaitGridColumns(session, 120, timeout: 30)
        awaitQuiet(session)
        report("\(label), 100ms throttle", runSimulatedDrag(session, applied: applied, throttleInterval: 0.1))
    }

    print("resize delivery strategies (P03), scripted drag 120 -> 80 columns:")
    dragPair("empty scrollback")

    // Fill the scrollback to its 100k limit through the real PTY. The lines
    // wrap at 120 columns (124 chars), matching `benchmarkReflowCost`'s
    // corpus — a non-wrapping fill reflows far cheaper and would understate
    // the worst case this comparison exists to bound. Kernel echo plus
    // `cat`'s own output push several rows per written line; the write cap
    // only bounds a broken pipe.
    let line = Array((String(repeating: "the quick brown fox jumps over ", count: 4) + "\r\n").utf8)
    var written = 0
    while session.snapshot().scrollback.totalPushed < 100_000, written < 150_000 {
        for _ in 0..<500 { session.write(line) }
        written += 500
        usleep(20_000)
    }
    awaitQuiet(session)
    let filled = session.snapshot().scrollback.totalPushed
    if filled < 100_000 {
        print("  warning: scrollback fill stalled at \(filled) pushed rows; full-scrollback run is lower-cost than intended")
    }
    dragPair("100k-line scrollback")
}

benchmarkResizeStrategies()

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

// MARK: - Snapshot latency under an output flood (P02)

/// What the render thread experiences when it asks for a grid while the
/// reader thread is feeding a flood: `snapshot()` must wait for the session
/// lock, which the reader holds across `feed` (in bounded slices). Samples
/// are interleaved with a quiet control session sampled in the same run, so
/// ambient scheduler preemption — which dominates the tail on a loaded
/// machine — shows up in the control rather than being mistaken for lock
/// wait.
///
/// The sampling thread runs at `.userInteractive`, the QoS of the main
/// thread in the app. That is not cosmetic: the reader thread runs at
/// `.userInitiated`, and a lower-priority waiter on `os_unfair_lock` loses
/// the re-acquire race to the higher-priority holder at every slice
/// boundary — measured as p99 ~30–106 ms (whole-batch starvation) from a
/// default-QoS sampler, while the same code measured from the QoS the
/// render thread actually has shows the numbers below.
func benchmarkSnapshotLatencyUnderFlood() {
    let flooded: TerminalSession
    let control: TerminalSession
    do {
        flooded = try TerminalSession(executable: "/usr/bin/yes", size: TerminalSize(rows: 50, columns: 200))
        control = try TerminalSession(executable: "/bin/cat", size: TerminalSize(rows: 50, columns: 200))
    } catch {
        print("snapshot latency under flood: SKIPPED (could not spawn children: \(error))")
        return
    }
    defer { flooded.stop(); control.stop() }
    flooded.start()
    control.start()

    // Let the flood establish so every sample contends with an in-flight
    // feed rather than a quiet child.
    let warmupDeadline = DispatchTime.now() + .milliseconds(300)
    while DispatchTime.now() < warmupDeadline {
        _ = flooded.snapshot()
    }

    let iterations = 2_000
    let floodSamples = Mutex([UInt64]())
    let controlSamples = Mutex([UInt64]())
    floodSamples.withLock { $0.reserveCapacity(iterations) }
    controlSamples.withLock { $0.reserveCapacity(iterations) }
    let samplerDone = Mutex(false)
    let sampler = Thread {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
        for _ in 0..<iterations {
            var start = DispatchTime.now()
            _ = flooded.snapshot()
            floodSamples.withLock {
                $0.append(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds)
            }
            start = DispatchTime.now()
            _ = control.snapshot()
            controlSamples.withLock {
                $0.append(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds)
            }
        }
        samplerDone.withLock { $0 = true }
    }
    sampler.start()
    while !samplerDone.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.01) }

    guard let floodDistribution = LatencyDistribution(
        samplesNanoseconds: floodSamples.withLock { $0 }),
          let controlDistribution = LatencyDistribution(
            samplesNanoseconds: controlSamples.withLock { $0 })
    else {
        print("snapshot latency under flood: NO DATA")
        return
    }
    print(
        "snapshot latency under flood: \(floodDistribution.description) "
            + "(lock wait + COW copy while the reader feeds a `yes` flood; sampled at .userInteractive QoS)")
    print(
        "snapshot latency, quiet control: \(controlDistribution.description) "
            + "(same machine, same run — the ambient-preemption baseline)")
}

benchmarkSnapshotLatencyUnderFlood()

// MARK: - Write-path backpressure (P01)

/// What the caller of `session.write` pays while the child never reads its
/// stdin (`sleep`). On Darwin a pty's input side absorbs on the order of a
/// hundred MB before `write(2)` starts stalling, and from there each write
/// costs tens of ms and soon blocks indefinitely — on the main thread that
/// is a hung UI (a runaway child that stops reading, e.g. `yes`, gets here
/// from ordinary typing alone). The bench pre-fills that buffer, then times
/// one more 1 MB write from the caller's thread. A queued implementation
/// pays microseconds to enqueue; a synchronous one pays the stall.
func benchmarkWriteBackpressure() {
    let session: TerminalSession
    do {
        session = try TerminalSession(
            executable: "/bin/sh", arguments: ["-c", "exec sleep 20"],
            size: TerminalSize(rows: 24, columns: 80))
    } catch {
        print("write backpressure: SKIPPED (could not spawn /bin/sh: \(error))")
        return
    }
    defer { session.stop() }

    let chunk = [UInt8](repeating: UInt8(ascii: "x"), count: 1024 * 1024)
    let prefill = 96
    let prefillStart = DispatchTime.now()
    for _ in 0..<prefill {
        session.write(chunk)
    }
    let prefillElapsed = DispatchTime.now().uptimeNanoseconds - prefillStart.uptimeNanoseconds

    let timedStart = DispatchTime.now()
    session.write(chunk)
    let timedElapsed = DispatchTime.now().uptimeNanoseconds - timedStart.uptimeNanoseconds

    print(
        "write backpressure (child not reading): caller-side cost of 1 MB write with full pty buffer: "
            + "\(String(format: "%.1f", Double(timedElapsed) / 1e6)) ms "
            + "(\(prefill) MB pre-fill cost the caller \(String(format: "%.1f", Double(prefillElapsed) / 1e6)) ms in total)")

    // Release the kernel's buffered input before the bench exits.
    session.stop()
    _ = session.pty.waitForExit(timeout: .seconds(5))
}

benchmarkWriteBackpressure()

// MARK: - Peak RSS for this run (P11)

/// `ru_maxrss` is bytes on Darwin. Read at the very end so it covers the
/// heaviest benchmark in the process — the run's own peak, not the app's.
func peakResidentBytes() -> UInt64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return UInt64(usage.ru_maxrss)
}

// MARK: - Search response distribution (P11)

/// The single-shot `benchmarkSearchCost` above answers "how expensive is one
/// query"; P11 wants the distribution a user actually hits — the cold first
/// query (allocator and caches cold, which is what the first keystroke of a
/// search feels) reported separately from the warmed steady state.
func benchmarkSearchResponseDistribution() {
    var terminal = Terminal(rows: 50, columns: 120, scrollbackLimit: 100_000)
    let line = "the quick brown fox jumps over the lazy dog\r\n"
    let lineBytes = Array(line.utf8)
    for _ in 0..<100_000 {
        terminal.feed(lineBytes)
    }

    let coldStart = DispatchTime.now()
    _ = Search.find("fox", in: terminal.grid)
    let coldMs = Double(DispatchTime.now().uptimeNanoseconds - coldStart.uptimeNanoseconds) / 1e6

    var samplesNanoseconds: [UInt64] = []
    samplesNanoseconds.reserveCapacity(50)
    for _ in 0..<50 {
        let start = DispatchTime.now()
        _ = Search.find("fox", in: terminal.grid)
        samplesNanoseconds.append(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds)
    }
    guard let warmed = LatencyDistribution(samplesNanoseconds: samplesNanoseconds) else { return }
    print(
        "search response, 100k-line scrollback: cold \(String(format: "%.1f", coldMs)) ms, "
            + "then warmed \(warmed.description)")
}

benchmarkSearchResponseDistribution()

// MARK: - Session spawn decomposition (P09)

/// What "time to first prompt" is made of below the app: (a) the spawn
/// handshake alone (the `TerminalSession` initialiser returns once
/// corta-exec has exec'd and reported back), (b) an exec floor —
/// `/usr/bin/true` from spawn to child-exit, (c) `/bin/zsh -f`, zsh's own
/// startup with no rc files, and (d) `/bin/zsh -l`, the login shell the app
/// actually spawns (`ViewController` passes `-l`), so (d) minus (c) is the
/// user's rc files, which Corta cannot improve but the user pays at every
/// launch. (`/bin/true` no longer exists as a binary on macOS 26 — only the
/// `/usr/bin/true` path works, which is why an earlier draft of this
/// benchmark reported ENOENT.) Events are awaited on a semaphore signalled
/// by the callback itself, so the numbers carry no polling quantisation.
func benchmarkSessionSpawnDecomposition() {
    let iterations = 30

    var spawnSamples: [UInt64] = []
    spawnSamples.reserveCapacity(iterations)
    var failedSpawns = 0
    var firstFailure: String?
    for _ in 0..<iterations {
        let start = DispatchTime.now()
        do {
            let session = try TerminalSession(executable: "/usr/bin/true")
            spawnSamples.append(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds)
            session.stop()
        } catch {
            // Counted, not fatal: a transient spawn failure (the previous
            // benchmark's child still tearing down, a relink race on a
            // shared build directory) must not void the whole measurement.
            failedSpawns += 1
            if firstFailure == nil { firstFailure = "\(error)" }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    if let distribution = LatencyDistribution(samplesNanoseconds: spawnSamples) {
        print(
            "spawn decomposition [(a) PTY spawn handshake]: \(distribution.description)"
                + (failedSpawns > 0 ? " [\(failedSpawns) spawns failed, first: \(firstFailure ?? "?")]" : ""))
    } else {
        print("spawn decomposition [(a) PTY spawn handshake]: NO DATA (\(failedSpawns) failed, first: \(firstFailure ?? "?"))")
    }

    func measureFirstEvent(executable: String, arguments: [String], waitForExit: Bool, label: String) {
        var samples: [UInt64] = []
        samples.reserveCapacity(iterations)
        var timedOut = 0
        var failedSpawns = 0
        for _ in 0..<iterations {
            guard let session = try? TerminalSession(executable: executable, arguments: arguments)
            else {
                failedSpawns += 1
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            let semaphore = DispatchSemaphore(value: 0)
            let start = DispatchTime.now()
            if waitForExit {
                session.onChildExit = { _ in semaphore.signal() }
            } else {
                session.onOutput = { semaphore.signal() }
            }
            session.start()
            if semaphore.wait(timeout: .now() + 10) == .success {
                samples.append(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds)
            } else {
                timedOut += 1
            }
            session.stop()
        }
        guard let distribution = LatencyDistribution(samplesNanoseconds: samples) else {
            print("spawn decomposition [\(label)]: NO DATA (\(timedOut) timed out, \(failedSpawns) spawn failures)")
            return
        }
        print(
            "spawn decomposition [\(label)]: \(distribution.description)"
                + (timedOut > 0 ? " [\(timedOut) timed out]" : "")
                + (failedSpawns > 0 ? " [\(failedSpawns) spawn failures]" : ""))
    }

    measureFirstEvent(executable: "/usr/bin/true", arguments: [], waitForExit: true, label: "(b) exec floor, /usr/bin/true -> exit")
    measureFirstEvent(executable: "/bin/zsh", arguments: ["-f"], waitForExit: false, label: "(c) zsh -f -> first output")
    measureFirstEvent(executable: "/bin/zsh", arguments: ["-l"], waitForExit: false, label: "(d) zsh -l -> first output (as the app spawns it)")
}

benchmarkSessionSpawnDecomposition()

// MARK: - Multi-pane fixed cost (P07)

func currentThreadCount() -> Int {
    var threads: thread_act_array_t?
    var count = mach_msg_type_number_t(0)
    guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS else { return -1 }
    let result = Int(count)
    if let threads {
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(result) * vm_size_t(MemoryLayout<thread_act_t>.stride))
    }
    return result
}

/// The per-pane cost below the app: a PTY pair, a corta-exec helper exec, a
/// reader thread and the Terminal/grid state. Measured incrementally in one
/// process (0 -> 1 -> 2 -> 4 panes) with `/bin/cat` children, so each step's
/// resident-memory delta is the marginal cost of one more idle pane. RSS
/// granularity and allocator reuse make a single MB-scale delta noisy; treat
/// the 4-pane step as the number and the smaller steps as corroboration. The
/// renderer-side per-pane cost is app-level and measured separately with
/// CORTA_RENDER_METRICS.
func benchmarkMultiPaneFixedCost() {
    var sessions: [TerminalSession] = []
    defer { sessions.forEach { $0.stop() } }
    var previous = Int64(currentResidentBytes())
    var previousThreads = currentThreadCount()
    print("multi-pane fixed cost: 0 panes, resident \(String(format: "%.1f", Double(previous) / 1_048_576)) MB, threads \(previousThreads)")
    for target in [1, 2, 4] {
        while sessions.count < target {
            guard let session = try? TerminalSession(
                executable: "/bin/cat", size: TerminalSize(rows: 50, columns: 200))
            else {
                print("multi-pane fixed cost: ABORTED (spawn failed at pane \(sessions.count + 1))")
                return
            }
            session.start()
            sessions.append(session)
        }
        Thread.sleep(forTimeInterval: 0.3)
        let now = Int64(currentResidentBytes())
        let threads = currentThreadCount()
        print(
            "multi-pane fixed cost: \(target) pane(s), resident \(String(format: "%.1f", Double(now) / 1_048_576)) MB "
                + "(step delta \(String(format: "%.1f", Double(now - previous) / 1_048_576)) MB), "
                + "threads \(threads) (step delta \(threads - previousThreads))")
        previous = now
        previousThreads = threads
    }
}

benchmarkMultiPaneFixedCost()

// MARK: - Typing fairness with a flooding neighbour (P09)

/// The same round trip as `benchmarkKeypressLatency` — with the same
/// completion-counter attribution, so a late signal can never stand in for a
/// request's own echo — but measured on a `/bin/cat` session while a second
/// session runs `/usr/bin/yes` flat out next to it. P09's fairness question:
/// does one flooding pane starve another pane's echo?
func benchmarkKeypressFairnessUnderFlood() {
    guard let typing = try? TerminalSession(executable: "/bin/cat", size: TerminalSize(rows: 24, columns: 80)),
          let flood = try? TerminalSession(executable: "/usr/bin/yes", size: TerminalSize(rows: 50, columns: 200))
    else {
        print("keypress fairness under flood: SKIPPED (spawn failed)")
        return
    }
    defer { typing.stop(); flood.stop() }

    let completedOutputs = Mutex(0)
    let semaphore = DispatchSemaphore(value: 0)
    typing.onOutput = {
        completedOutputs.withLock { $0 += 1 }
        semaphore.signal()
    }
    typing.start()
    flood.start()
    Thread.sleep(forTimeInterval: 0.3)

    func awaitCompletion(target: Int, timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + .nanoseconds(Int(timeout * 1e9))
        while completedOutputs.withLock({ $0 }) < target {
            guard semaphore.wait(timeout: deadline) == .success else { return false }
        }
        return true
    }

    let warmupTarget = completedOutputs.withLock { $0 } + 1
    typing.write([UInt8(ascii: "a")])
    _ = awaitCompletion(target: warmupTarget, timeout: 1)

    var samplesNanoseconds: [UInt64] = []
    samplesNanoseconds.reserveCapacity(2_000)
    var timedOut = 0
    for i in 0..<2_000 {
        let byte = UInt8(ascii: "a") + UInt8(i % 26)
        let target = completedOutputs.withLock { $0 } + 1
        let start = DispatchTime.now()
        typing.write([byte])
        if awaitCompletion(target: target, timeout: 1) {
            samplesNanoseconds.append(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds)
        } else {
            timedOut += 1
            let resyncTarget = completedOutputs.withLock { $0 } + 1
            _ = awaitCompletion(target: resyncTarget, timeout: 0.2)
        }
    }
    guard let distribution = LatencyDistribution(samplesNanoseconds: samplesNanoseconds) else {
        print("keypress -> grid latency with a flooding neighbour: NO DATA (\(timedOut) timed out)")
        return
    }
    print(
        "keypress -> grid latency with a flooding neighbour: \(distribution.description) "
            + "[\(timedOut) timed out]")
}

benchmarkKeypressFairnessUnderFlood()

print("peak RSS across this run: \(String(format: "%.1f", megabytes(peakResidentBytes()))) MB")

