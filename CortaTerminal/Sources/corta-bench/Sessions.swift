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

import CortaPOSIX
import CortaTerminal
import Darwin
import Dispatch
import Foundation
import Synchronization

// Resizes, writes, reader priority, spawning and panes: costs a whole session pays.

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

/// Actual build/find children; parent CPU excludes their compilation/traversal.
func benchmarkRealReaderProducers(priority: TerminalSession.ReaderPriority) {
    let root = "/tmp/corta-reader-producers"
    let repositoryIndex = CommandLine.arguments.firstIndex(of: "--repository")
    let repository = repositoryIndex.flatMap { index in
        CommandLine.arguments.indices.contains(index + 1) ? CommandLine.arguments[index + 1] : nil
    }
    func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    let package = quote(repository ?? "\(root)/project")
    let find: String
    if CommandLine.arguments.contains("--bounded-root-find") {
        find = "/usr/bin/find / -xdev -maxdepth 4"
    } else if CommandLine.arguments.contains("--root-find") {
        find = "/usr/bin/find / -xdev"
    } else {
        find = "for n in 1 2 3 4 5 6 7 8 9 10; do /usr/bin/find '\(root)/tree' -type f; done"
    }
    func cpu(_ usage: rusage) -> Double {
        Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
    for round in 1...3 {
        let build = "\(root)/build-\(priority)-\(round)-\(UUID().uuidString)"
        let workloads = [("swift-build", "/usr/bin/swift build -v --package-path \(package) --scratch-path \(quote(build))"),
            ("find", find)]
        for (name, command) in workloads {
            do {
                var before = rusage()
                _ = getrusage(RUSAGE_SELF, &before)
                let start = DispatchTime.now().uptimeNanoseconds
                let session = try TerminalSession(executable: "/bin/sh", arguments: ["-c", command],
                    size: TerminalSize(rows: 4, columns: 200))
                let done = DispatchSemaphore(value: 0)
                let outcome = Mutex<ProcessExit?>(nil)
                session.onChildExit = { exit in outcome.withLock { $0 = exit }; done.signal() }
                session.setReaderPriority(priority)
                session.start()
                let finished = done.wait(timeout: .now() + 180) == .success
                var after = rusage()
                _ = getrusage(RUSAGE_SELF, &after)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                print("real-producer \(name) round=\(round) reader=\(session.readerPriority) finished=\(finished) exit=\(String(describing: outcome.withLock { $0 })) elapsed=\(String(format: "%.3f", elapsed))s parentCPU=\(String(format: "%.6f", cpu(after)-cpu(before)))s")
                fflush(stdout)
                session.stop()
            } catch { print("real-producer failed: \(error)") }
        }
    }
}

/// Actual child write durations, beside the CPU feed/backpressure drivers.
func benchmarkReaderProducer(priority: TerminalSession.ReaderPriority) {
    let script = """
        import os,time
        samples=[]
        line=b'x'*200+b'\\r\\n'
        begin=time.monotonic()
        for i in range(2000):
            deadline=begin+i/1000
            delay=deadline-time.monotonic()
            if delay>0: time.sleep(delay)
            before=time.perf_counter_ns()
            os.write(1,line)
            samples.append((time.perf_counter_ns()-before)/1000)
        samples.sort()
        os.write(1,('qos-producer p50=%.1fus p99=%.1fus max=%.1fus over1ms=%d\\r\\n' %
            (samples[1000],samples[1980],samples[-1],sum(v>1000 for v in samples))).encode())
        """
    do {
        let session = try TerminalSession(
            executable: "/usr/bin/python3", arguments: ["-c", script],
            size: TerminalSize(rows: 4, columns: 200))
        let done = DispatchSemaphore(value: 0)
        session.onChildExit = { _ in done.signal() }
        session.setReaderPriority(priority)
        session.start()
        defer { session.stop() }
        guard done.wait(timeout: .now() + 10) == .success else {
            print("qos producer timed out")
            return
        }
        print(
            "reader \(session.readerPriority): "
                + session.snapshot().logicalLines().map(\.text)
                .filter { $0.contains("qos-producer") }.joined(separator: " "))
    } catch { print("qos producer failed: \(error)") }
}

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

/// `--reader-qos [--utility] [--real-producers]`: the reader-side
/// benchmarks on a thread of the chosen QoS.
func benchmarkReaderQoS() {
    let utility = CommandLine.arguments.contains("--utility")
    let finished = DispatchSemaphore(value: 0)
    let thread = Thread {
        let qos = utility ? QOS_CLASS_UTILITY : QOS_CLASS_USER_INITIATED
        print(
            "reader QoS benchmark: \(utility ? "utility" : "user-initiated"), set=\(pthread_set_qos_class_self_np(qos, 0))"
        )
        if CommandLine.arguments.contains("--real-producers") {
            benchmarkRealReaderProducers(priority: utility ? .background : .interactive)
        } else {
            benchmarkFeedUnderSnapshotter()
            benchmarkWriteBackpressure()
            for _ in 0..<3 { benchmarkReaderProducer(priority: utility ? .background : .interactive) }
        }
        finished.signal()
    }
    thread.start()
    finished.wait()
}

