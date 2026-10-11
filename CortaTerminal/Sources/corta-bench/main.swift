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

import Compression
import CortaTerminal
import Darwin
import Dispatch
import Foundation
import Synchronization

let focusedHistoryBenchmarks = CommandLine.arguments.contains("--history") || CommandLine.arguments.contains("--reflow-only")

/// `corta-bench` — measures the numbers `docs/PERFORMANCE.md` §1 sets
/// targets for, so they are recorded, not estimated. Run release for real numbers:
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

func currentFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
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

// Synthetic workloads; never captured terminal output.
func benchmarkUnicodeCorpora() {
    struct Counter: ParserPerformer {
        var count = 0
        mutating func print(_ scalar: UInt32) { count &+= 1 }
        mutating func printASCII(_ bytes: ArraySlice<UInt8>) { count &+= bytes.count }
        mutating func execute(_ byte: UInt8) {}
    }
    for (name, line) in [
        ("ASCII", "\u{1B}[32mdrwxr-xr-x\u{1B}[0m user file.log\r\n"),
        ("CJK", "\u{1B}[32m终端性能测试 日本語の文章 输出历史与搜索\u{1B}[0m\r\n"),
        ("emoji", "┌────┐ │ ✅ 🚀 👩🏽‍💻 🌈 │ └────┘\r\n"),
        ("AI CLI", "\u{1B}[36m│ 分析代码 ✅\u{1B}[0m changes: +42 −12 ├── src/main.swift 🚀\r\n")
    ] {
        let unit = Array(line.utf8)
        let corpus = Array(repeating: unit, count: max(1, 8 * 1_048_576 / unit.count)).flatMap { $0 }
        let sampleOption = CommandLine.arguments.firstIndex(of: "--unicode-samples")
        let requested = sampleOption.flatMap { $0 + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[$0 + 1]) : nil } ?? 5
        let sampleCount = min(20, max(1, requested))
        for mode in 0..<3 {
            var samples: [Double] = []
            var checksum = 0
            for iteration in 0...sampleCount {
                var parser = Parser(), counter = Counter()
                var terminal = Terminal(rows: 50, columns: 200, scrollbackLimit: mode == 1 ? 0 : 10_000)
                let start = DispatchTime.now().uptimeNanoseconds
                if mode == 0 { parser.parse(corpus, performer: &counter) }
                else { terminal.feed(corpus) }
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                if iteration > 0 { samples.append(seconds) }
                checksum &+= counter.count + terminal.grid.scrollback.count + terminal.grid.cursor.column
                    + Int(terminal.grid.line(0)[0].scalar)
            }
            samples.sort()
            let rate = throughput(corpus.count, elapsedSeconds: samples[samples.count / 2])
            let low = throughput(corpus.count, elapsedSeconds: samples.last!)
            let high = throughput(corpus.count, elapsedSeconds: samples.first!)
            print("unicode \(name) \(["parser", "grid", "feed"][mode]): \(String(format: "%.1f", rate)) MiB/s checksum \(checksum) (n=\(sampleCount), range \(String(format: "%.1f", low))–\(String(format: "%.1f", high)), one warmup)")
        }

    }
}

func benchmarkCompressionCodecs() {
    for name in ["SGR ls", "log", "CJK"] {
        var terminal = Terminal(rows: 1, columns: 120, scrollbackLimit: 100_000)
        for row in 0..<100_001 {
            let text: String
            switch name {
            case "SGR ls": text = "\u{1B}[\(31 + row % 7)mdrwxr-xr-x\u{1B}[0m user file-\(row).log " + String(repeating: "abc", count: 29)
            case "log": text = "2026-10-11 INFO request \(row) status=\(200 + row % 5) latency=\(row % 997)ms " + String(repeating: "data", count: 16)
            default: text = "记录 \(row) 终端历史压缩测试 日本語の文章 输出历史与搜索 " + String(repeating: "中文", count: 14)
            }
            terminal.feed(Array((text + "\r\n").utf8))
        }
        for (codecName, codec) in [("LZ4", COMPRESSION_LZ4), ("LZFSE", COMPRESSION_LZFSE)] {
            for shuffled in [false, true] {
                var rawBytes = 0, encodedBytes = 0
                var encodeNS: UInt64 = 0, decodeNS: UInt64 = 0
                terminal.grid.scrollback.withCellBatches { cells in
                    let raw = Array(UnsafeRawBufferPointer(cells))
                    guard !raw.isEmpty else { return }
                    let count = cells.count, stride = MemoryLayout<Cell>.stride
                    let start = DispatchTime.now().uptimeNanoseconds
                    var source = raw
                    if shuffled {
                        source = [UInt8](repeating: 0, count: raw.count)
                        for byte in 0..<stride { for cell in 0..<count { source[byte * count + cell] = raw[cell * stride + byte] } }
                    }
                    var output = [UInt8](repeating: 0, count: source.count + 65536)
                    let size = source.withUnsafeBufferPointer { src in output.withUnsafeMutableBufferPointer { dst in
                        compression_encode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil, codec)
                    } }
                    encodeNS += DispatchTime.now().uptimeNanoseconds - start
                    precondition(size > 0)
                    let decodeStart = DispatchTime.now().uptimeNanoseconds
                    var decoded = [UInt8](repeating: 0, count: raw.count)
                    let sizeOut = output.withUnsafeBufferPointer { src in decoded.withUnsafeMutableBufferPointer { dst in
                        compression_decode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, size, nil, codec)
                    } }
                    if shuffled {
                        var unshuffled = [UInt8](repeating: 0, count: raw.count)
                        for byte in 0..<stride { for cell in 0..<count { unshuffled[cell * stride + byte] = decoded[byte * count + cell] } }
                        decoded = unshuffled
                    }
                    decodeNS += DispatchTime.now().uptimeNanoseconds - decodeStart
                    precondition(sizeOut == raw.count && decoded == raw)
                    rawBytes += raw.count; encodedBytes += size
                }
                print("compression \(name) 100k rows \(codecName) \(shuffled ? "shuffled" : "raw"): \(String(format: "%.2f", Double(rawBytes) / Double(encodedBytes)))x encode \(String(format: "%.1f", throughput(rawBytes, elapsedSeconds: Double(encodeNS) / 1e9))) decode \(String(format: "%.1f", throughput(rawBytes, elapsedSeconds: Double(decodeNS) / 1e9))) MiB/s including shuffle/scratch; raw bytes \(rawBytes)")
            }
        }
    }
}

// MARK: - Scrollback memory at 100k lines

func benchmarkScrollbackMemory() {
    let before = currentResidentBytes()
    let footprintBefore = currentFootprintBytes()
    var terminal = Terminal(rows: 50, columns: 200, scrollbackLimit: 100_000)
    // 100k lines of realistic width so evicted rows aren't free of cost.
    let line = String(repeating: "x", count: 120) + "\r\n"
    let lineBytes = Array(line.utf8)
    for row in 0..<100_000 {
        terminal.feed(lineBytes)
        // Standalone Terminal has no reader queue. Model the session's idle
        // maintenance as batches seal, rather than deferring a whole history.
        if row.isMultiple(of: 256) { terminal.compressColdScrollback() }
    }
    terminal.compressColdScrollback()
    let footprintAfter = currentFootprintBytes()
    let after = currentResidentBytes()
    print("compressed history footprint delta: \(Int64(footprintAfter) - Int64(footprintBefore)) bytes")
    print(
        "memory @ 100k scrollback lines: \(String(format: "%.1f", Double(Int64(after) - Int64(before)) / 1_048_576)) MB "
            + "(resident before \(String(format: "%.1f", megabytes(before))) MB, after \(String(format: "%.1f", megabytes(after))) MB)"
    )
}

// MARK: - Keypress -> grid latency (PERFORMANCE.md §1)

/// The software round-trip a keypress causes before there is anything new
/// for the renderer to draw: write to the PTY, the byte comes back, the
/// reader thread parses it and applies it to the grid. Three things this is
/// NOT, stated plainly because it would be easy to overstate this number:
///
/// 1. It is not a full keypress-to-photon measurement. That also needs one
///    vsync period (already bounded by `FrameCPUBaselineTests`, < 4 ms CPU
///    against an 8.3 ms 120 Hz frame) plus real display/compositor latency,
///    which needs the app's own end-to-end measure (`RenderMetrics.keypressToPresent`) and cannot
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

    // Request/completion correlation. `onOutput` carries no payload,
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

/// A profiler target: warm the history ring, then repeat the yes corpus
/// without retaining snapshots. The marker separates initial capacity growth
/// from steady-state recycling in an Allocations call tree.
func profileSteadyScrolling() {
    var terminal = Terminal(rows: 40, columns: 120, scrollbackLimit: 100_000)
    let bytes = Array([UInt8]("y\r\n".utf8).repeated(toCount: 1_048_576))
    terminal.feed(bytes)
    print("scroll allocations: STEADY begins (history warmed, no snapshotter)")
    fflush(stdout)
    let deadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
    var batches = 0
    while DispatchTime.now().uptimeNanoseconds < deadline {
        terminal.feed(bytes)
        batches += 1
    }
    print("scroll allocations: STEADY ends (\(batches) MiB batches)")
}

@inline(never) func makeColdHistory() -> Grid {
    var terminal = Terminal(rows: 50, columns: 120, scrollbackLimit: 100_000)
    for row in 0..<100_050 {
        terminal.feed(Array(("log \(row) " + String(repeating: "abcdef0123456789", count: 6) + " needle\r\n").utf8))
        if !CommandLine.arguments.contains("--deferred"), row.isMultiple(of: 256) { terminal.compressColdScrollback() }
    }
    return terminal.grid
}
if CommandLine.arguments.contains("--cold-history") {
    var grid = makeColdHistory()
    print("history before drain cells \(grid.scrollback.storedCellBytes) RSS \(currentResidentBytes()) footprint \(currentFootprintBytes())")
    let start = DispatchTime.now().uptimeNanoseconds
    grid.scrollback.compressColdBatches()
    var mallocStats = malloc_statistics_t()
    malloc_zone_statistics(nil, &mallocStats)
    print("malloc in use \(mallocStats.size_in_use) allocated \(mallocStats.size_allocated)")
    print("history compressed cells \(grid.scrollback.storedCellBytes) capacity \(grid.scrollback.retainedCellCapacityBytes) RSS \(currentResidentBytes()) footprint \(currentFootprintBytes()) batches \(grid.scrollback.compressedBatchCount) encode ms \(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)")
    for query in ["absent", "needle", "log 90000"] {
        for run in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            let matches = Search.find(query, in: grid)
            print("history search \(query) run \(run): \(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6) ms count \(matches.count) RSS \(currentResidentBytes())")
        }
    }
    let reflow = DispatchTime.now().uptimeNanoseconds
    grid.resize(rows: 50, columns: 80)
    print("history reflow ms \(Double(DispatchTime.now().uptimeNanoseconds - reflow) / 1e6) RSS \(currentResidentBytes())")
    exit(0)
}
if CommandLine.arguments.contains("--profile-cjk") {
    let bytes = Array(String(repeating: "\u{1B}[32m终端性能测试 日本語の文章 输出历史与搜索\u{1B}[0m\r\n", count: 10000).utf8)
    var terminal = Terminal(rows: 50, columns: 200, scrollbackLimit: 10000)
    for _ in 0..<2000 { terminal.feed(bytes) }
    print(terminal.grid.scrollback.totalPushed)
    exit(0)
}
if CommandLine.arguments.contains("--search-only") {
    var grid = { () -> Grid in
        var terminal = Terminal(rows: 50, columns: 120, scrollbackLimit: 100_000)
        for _ in 0..<100_000 { terminal.feed(Array("the quick brown fox jumps over the lazy dog\r\n".utf8)) }
        return terminal.grid
    }()
    if CommandLine.arguments.contains("--compressed") { grid.scrollback.compressColdBatches() }
    for _ in 0..<5 {
        let start = DispatchTime.now().uptimeNanoseconds
        let matches = Search.find("fox", in: grid)
        print("search-only \(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6) ms \(matches.count)")
    }
    exit(0)
}
if CommandLine.arguments.contains("--unicode") { benchmarkUnicodeCorpora(); exit(0) }
if CommandLine.arguments.contains("--compression") { benchmarkCompressionCodecs(); exit(0) }
if CommandLine.arguments.contains("--scroll-allocations") {
    profileSteadyScrolling()
    exit(0)
}
if CommandLine.arguments.contains("--memory-only") {
    benchmarkScrollbackMemory()
    exit(0)
}
if !focusedHistoryBenchmarks { benchmarkParseThroughput() }
if !focusedHistoryBenchmarks { benchmarkScrollbackMemory() }
if !focusedHistoryBenchmarks { benchmarkKeypressLatency() }

// MARK: - Where the 100k-line memory actually goes

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

if !focusedHistoryBenchmarks { diagnoseScrollbackFootprint() }

// MARK: - Reflow cost on a full scrollback

/// `ResizeDebouncer` is trailing-only: a drag in continuous motion delivers
/// nothing until the stream pauses for 100ms or ends, so "stays smooth"
/// means one reflow after the gesture, not one inside a frame budget. The
/// throttle alternative is measured head-to-head in
/// `benchmarkResizeStrategies` below.
func benchmarkReflowCost() {
    var terminal = Terminal(rows: 50, columns: 120, scrollbackLimit: 100_000)
    let line = String(repeating: "the quick brown fox jumps over ", count: 4) + "\r\n"  // wraps at 120
    let lineBytes = Array(line.utf8)
    for _ in 0..<100_000 {
        terminal.feed(lineBytes)
    }

    if CommandLine.arguments.contains("--compressed") { terminal.compressColdScrollback() }
    let start = DispatchTime.now()
    var grid = terminal.grid
    grid.resize(rows: 50, columns: 80)
    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
    print(
        "reflow cost, 100k-line scrollback, 120 -> 80 columns: \(String(format: "%.1f", elapsedMs)) ms "
            + "(one resize call; ResizeDebouncer coalesces a live drag to ~1 call/100ms)")
}

if CommandLine.arguments.contains("--reflow-only") { benchmarkReflowCost(); exit(0) }
benchmarkReflowCost()

// MARK: - Resize delivery strategies

/// What a live window drag costs the core under the two resize delivery
/// policies, run against a real session — real PTY, real `resizeQueue`
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

    print("resize delivery strategies, scripted drag 120 -> 80 columns:")
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

if !focusedHistoryBenchmarks { benchmarkResizeStrategies() }

// MARK: - Search cost over a full scrollback

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

if !focusedHistoryBenchmarks { benchmarkSearchCost() }

// MARK: - Snapshot latency under an output flood

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

if !focusedHistoryBenchmarks { benchmarkSnapshotLatencyUnderFlood() }

// MARK: - Feed throughput under a 60 Hz snapshotter

/// The reader-side cost of a snapshot that outlives its frame. A `Grid`
/// snapshot shares the scrollback's arenas; while it lives, the next
/// `Scrollback.push` copies the `batches` array and the whole tail arena
/// (up to 256 rows × width × 16 bytes). The app releases its snapshot as
/// soon as `prepareFrame` has diffed it; until 1.1.0 it held one until the
/// next frame.
///
/// The reader feeds in the session's 16 KiB lock slices while a thread
/// takes a snapshot under the same lock at 60 Hz and either drops it at
/// once or holds it until the next tick. Two corpora: `yes`-shaped lines,
/// which trim to one cell so the arena copy is small, and full-width lines,
/// the worst case. Runs alternate so the machine's drift lands on all three.
func benchmarkFeedUnderSnapshotter() {
    enum Snapshots: String, CaseIterable {
        case none = "no snapshotter"
        case dropped = "60 Hz, released at once"
        case held = "60 Hz, held to the next tick"
    }
    let columns = 200
    let fullWidth = Array((String(repeating: "x", count: columns) + "\r\n").utf8)
    let corpora: [(name: String, bytes: [UInt8])] = [
        ("`yes` lines", Array([UInt8]("y\r\n".utf8).repeated(toCount: 32 * 1_048_576))),
        ("\(columns)-column lines", fullWidth.repeated(toCount: 64 * 1_048_576)),
    ]
    let sliceSize = 16 * 1024
    let runs = 3

    func feedSeconds(_ corpus: [UInt8], _ mode: Snapshots) -> Double {
        let state = Mutex(Terminal(rows: 50, columns: columns, scrollbackLimit: 10_000))
        let stop = Atomic(false)
        let finished = DispatchSemaphore(value: 0)
        let snapshotter = Thread {
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
            var held: Grid?
            while !stop.load(ordering: .relaxed) {
                // Assigned or discarded in the statement that takes it, so
                // a dropped snapshot cannot live on through the sleep.
                if mode == .held {
                    held = state.withLock { $0.grid }
                } else {
                    _ = state.withLock { $0.grid }
                }
                withExtendedLifetime(held) { Thread.sleep(forTimeInterval: 1.0 / 60) }
            }
            withExtendedLifetime(held) {}
            held = nil
            finished.signal()
        }
        if mode != .none { snapshotter.start() }
        let start = DispatchTime.now()
        var offset = 0
        while offset < corpus.count {
            let end = min(offset + sliceSize, corpus.count)
            let slice = Array(corpus[offset..<end])
            state.withLock { $0.feed(slice) }
            offset = end
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        stop.store(true, ordering: .relaxed)
        // Joined, so its last snapshot is freed before the next run's clock.
        if mode != .none { finished.wait() }
        return elapsed
    }

    for corpus in corpora {
        var seconds: [Snapshots: [Double]] = [:]
        for _ in 0..<runs {
            for mode in Snapshots.allCases {
                seconds[mode, default: []].append(feedSeconds(corpus.bytes, mode))
            }
        }
        for mode in Snapshots.allCases {
            let rates = seconds[mode, default: []].map {
                throughput(corpus.bytes.count, elapsedSeconds: $0)
            }
            let median = rates.sorted()[rates.count / 2]
            print(
                "feed throughput, \(corpus.name), \(mode.rawValue): "
                    + "\(String(format: "%.1f", median)) MiB/s median of \(runs) "
                    + "(\(rates.map { String(format: "%.1f", $0) }.joined(separator: " / ")))")
        }
    }

    // The copy itself, which the throughput runs only see diluted: one
    // full-width line fed into a full scrollback, with a snapshot alive or
    // not. The first is what every frame paid while a snapshot outlived it.
    var terminal = Terminal(rows: 50, columns: columns, scrollbackLimit: 10_000)
    terminal.feed(fullWidth.repeated(toCount: fullWidth.count * 10_100))
    var alone: [UInt64] = []
    var shared: [UInt64] = []
    for iteration in 0..<2_000 {
        let snapshot: Grid? = iteration.isMultiple(of: 2) ? terminal.grid : nil
        let start = DispatchTime.now()
        terminal.feed(fullWidth)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        if snapshot == nil { alone.append(elapsed) } else { shared.append(elapsed) }
        withExtendedLifetime(snapshot) {}
    }
    if let alone = LatencyDistribution(samplesNanoseconds: alone),
        let shared = LatencyDistribution(samplesNanoseconds: shared)
    {
        print("one \(columns)-column line into a full scrollback, nothing sharing it: \(alone.description)")
        print("the same line with a snapshot alive (the copy-on-write): \(shared.description)")
    }
}

extension Array where Element == UInt8 {
    /// `self` repeated until at least `count` bytes.
    fileprivate func repeated(toCount count: Int) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(count + self.count)
        while result.count < count { result.append(contentsOf: self) }
        return result
    }
}

if !focusedHistoryBenchmarks { benchmarkFeedUnderSnapshotter() }

// MARK: - Main-actor wakes under a flood

/// How often a flooding session would hop to the main actor. The reader
/// calls `onOutput` per parse batch; the app wakes the main actor only when
/// its `OutputWakeGate` was idle, and the frame re-arms it. A thread taking
/// the flag at 60 Hz stands in for the display link, so the gated rate
/// should sit at or under 60 a second whatever the batch rate is.
func benchmarkOutputWakesUnderFlood() {
    let session: TerminalSession
    do {
        session = try TerminalSession(
            executable: "/usr/bin/yes", size: TerminalSize(rows: 50, columns: 200))
    } catch {
        print("main-actor wakes under flood: SKIPPED (could not spawn /usr/bin/yes: \(error))")
        return
    }
    defer { session.stop() }
    let gate = OutputWakeGate()
    let batches = Atomic(0)
    let wakes = Atomic(0)
    session.onOutput = {
        batches.add(1, ordering: .relaxed)
        if gate.noteOutput() { wakes.add(1, ordering: .relaxed) }
    }
    let stop = Atomic(false)
    let frames = Thread {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
        while !stop.load(ordering: .relaxed) {
            _ = gate.takePending()
            Thread.sleep(forTimeInterval: 1.0 / 60)
        }
    }
    session.start()
    Thread.sleep(forTimeInterval: 0.3)
    frames.start()
    let startBatches = batches.load(ordering: .relaxed)
    let startWakes = wakes.load(ordering: .relaxed)
    let seconds = 3.0
    Thread.sleep(forTimeInterval: seconds)
    let batchRate = Double(batches.load(ordering: .relaxed) - startBatches) / seconds
    let wakeRate = Double(wakes.load(ordering: .relaxed) - startWakes) / seconds
    stop.store(true, ordering: .relaxed)
    print(
        "main-actor wakes under flood: \(String(format: "%.0f", wakeRate))/s gated "
            + "against \(String(format: "%.0f", batchRate)) parse batches/s "
            + "(a `yes` flood, frames taken at 60 Hz)")
}

if !focusedHistoryBenchmarks { benchmarkOutputWakesUnderFlood() }

// MARK: - Write-path backpressure

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

if !focusedHistoryBenchmarks { benchmarkWriteBackpressure() }

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

if !focusedHistoryBenchmarks { benchmarkSearchResponseDistribution() }

/// The case the ASCII fast path (#115) cannot take, and the one it could
/// make *worse*: an ASCII query over a document whose lines are not ASCII,
/// so `fillWithASCIILogicalLine` is attempted and rejected on every line
/// before the `String` path runs anyway. If this number moves up, the fast
/// path is being paid for by the searches that cannot use it.
///
/// The non-ASCII character sits at the *end* of the line deliberately. Put
/// it near the front and the byte walk bails after a few cells, which is
/// the cheap case and measures almost nothing; a log line terminated by a
/// status glyph — `✓`, `…`, a box-drawing character — makes the walk
/// traverse the whole chain before rejecting it, so the row is walked
/// twice. That is the shape this guard has to be able to see.
func benchmarkNonASCIISearchResponse() {
    var terminal = Terminal(rows: 50, columns: 120, scrollbackLimit: 100_000)
    let line = "the quick brown fox jumps over the lazy dog ✓\r\n"
    let lineBytes = Array(line.utf8)
    for _ in 0..<100_000 {
        terminal.feed(lineBytes)
    }

    var samplesNanoseconds: [UInt64] = []
    samplesNanoseconds.reserveCapacity(50)
    for _ in 0..<50 {
        let start = DispatchTime.now()
        _ = Search.find("fox", in: terminal.grid)
        samplesNanoseconds.append(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds)
    }
    guard let warmed = LatencyDistribution(samplesNanoseconds: samplesNanoseconds) else { return }
    print(
        "search response, 100k-line non-ASCII scrollback, ASCII query: "
            + warmed.description)
}

benchmarkNonASCIISearchResponse()

// MARK: - Session spawn decomposition

/// What "time to first prompt" is made of below the app: (a) the spawn
/// handshake alone (the `TerminalSession` initialiser returns once
/// corta-exec has exec'd and reported back), (b) an exec floor —
/// `/usr/bin/true` from spawn to child-exit, (c) `/bin/zsh -f`, zsh's own
/// startup with no rc files, and (d) `/bin/zsh -l`, the login shell the app
/// actually spawns (`ViewController` passes `-l`), so (d) minus (c) is the
/// user's rc files, which Corta cannot improve but the user pays at every
/// launch. (`/bin/true` is not a binary on macOS 26 — only `/usr/bin/true`
/// exists; spawning the former fails with ENOENT.) Events are awaited on a semaphore signalled
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

if !focusedHistoryBenchmarks { benchmarkSessionSpawnDecomposition() }

// MARK: - Multi-pane fixed cost

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

if !focusedHistoryBenchmarks { benchmarkMultiPaneFixedCost() }

// MARK: - Typing fairness with a flooding neighbour

/// The same round trip as `benchmarkKeypressLatency` — with the same
/// completion-counter attribution, so a late signal can never stand in for a
/// request's own echo — but measured on a `/bin/cat` session while a second
/// session runs `/usr/bin/yes` flat out next to it. The question is
/// fairness: does one flooding pane starve another pane's echo?
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

if !focusedHistoryBenchmarks { benchmarkKeypressFairnessUnderFlood() }

print("peak RSS across this run: \(String(format: "%.1f", megabytes(peakResidentBytes()))) MB")

