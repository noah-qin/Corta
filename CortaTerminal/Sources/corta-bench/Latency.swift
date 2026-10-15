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
import Darwin
import Dispatch
import Foundation
import Synchronization

// Keypress, snapshot and wake latency, alone and under an output flood.

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

    let counter = EchoCounter(observing: session)
    // Configure-before-start: the reader thread only begins draining the
    // PTY here, after `onOutput` is installed.
    session.start()
    // 200 samples cannot support a p99 — the 99th percentile of 200 is the
    // second-largest value, which is one scheduling hiccup away from being
    // noise. 2000 keeps the whole run under a couple of seconds and makes
    // the p99 a number rather than an anecdote.
    let run = measureEchoRoundTrips(session, counter: counter, iterations: 2_000, abortAfterConsecutiveTimeouts: 8)
    let samplesNanoseconds = run.samples
    let submitted = run.submitted
    let timedOut = run.timedOut
    let aborted = run.aborted

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
    let columns = 200
    let fullWidth = Array((String(repeating: "x", count: columns) + "\r\n").utf8)
    let corpora: [(name: String, bytes: [UInt8])] = [
        ("`yes` lines", Array([UInt8]("y\r\n".utf8).repeated(toCount: 32 * 1_048_576))),
        ("\(columns)-column lines", fullWidth.repeated(toCount: 64 * 1_048_576)),
    ]
    let runs = 3
    for corpus in corpora {
        var seconds: [SnapshotMode: [Double]] = [:]
        for _ in 0..<runs {
            for mode in SnapshotMode.allCases {
                seconds[mode, default: []].append(feedSeconds(corpus.bytes, columns: columns, snapshots: mode))
            }
        }
        for mode in SnapshotMode.allCases {
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
    measureSnapshotCopy(of: fullWidth, columns: columns)
}

private enum SnapshotMode: String, CaseIterable {
    case none = "no snapshotter"
    case dropped = "60 Hz, released at once"
    case held = "60 Hz, held to the next tick"
}

/// Seconds to feed `corpus` in 16 KiB lock slices while a thread takes
/// snapshots under the same lock as `snapshots` says.
private func feedSeconds(_ corpus: [UInt8], columns: Int, snapshots mode: SnapshotMode) -> Double {
    let sliceSize = 16 * 1024
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

/// The copy itself, which the throughput runs only see diluted: one
/// full-width line fed into a full scrollback, with a snapshot alive or
/// not. The first is what every frame paid while a snapshot outlived it.
private func measureSnapshotCopy(of line: [UInt8], columns: Int) {
    var terminal = Terminal(rows: 50, columns: columns, scrollbackLimit: 10_000)
    terminal.feed(line.repeated(toCount: line.count * 10_100))
    var alone: [UInt64] = []
    var shared: [UInt64] = []
    for iteration in 0..<2_000 {
        let snapshot: Grid? = iteration.isMultiple(of: 2) ? terminal.grid : nil
        let start = DispatchTime.now()
        terminal.feed(line)
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

    let counter = EchoCounter(observing: typing)
    typing.start()
    flood.start()
    Thread.sleep(forTimeInterval: 0.3)
    let run = measureEchoRoundTrips(typing, counter: counter, iterations: 2_000, abortAfterConsecutiveTimeouts: nil)
    let samplesNanoseconds = run.samples
    let timedOut = run.timedOut
    guard let distribution = LatencyDistribution(samplesNanoseconds: samplesNanoseconds) else {
        print("keypress -> grid latency with a flooding neighbour: NO DATA (\(timedOut) timed out)")
        return
    }
    print(
        "keypress -> grid latency with a flooding neighbour: \(distribution.description) "
            + "[\(timedOut) timed out]")
}

/// A session's output signals, counted. `onOutput` carries no payload, so a
/// semaphore signal alone cannot say *which* write produced it: a signal
/// from a timed-out write arriving late would be consumed by the next
/// write's wait and recorded as that write's near-zero "latency". A round
/// trip is recorded only once the count has advanced past the value taken
/// at submission, so a stale signal can never stand in for a request's own
/// echo.
final class EchoCounter: Sendable {
    private let completed = Mutex(0)
    private let signal = DispatchSemaphore(value: 0)

    /// Installs itself as `session.onOutput`; call before `start()`.
    init(observing session: TerminalSession) {
        session.onOutput = { [self] in
            completed.withLock { $0 += 1 }
            signal.signal()
        }
    }

    var count: Int { completed.withLock { $0 } }

    /// Waits until the count reaches `target` or `timeout` elapses. The
    /// semaphore only paces the recheck; the count is the authority on
    /// which requests have completed.
    func wait(until target: Int, timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + .nanoseconds(Int(timeout * 1e9))
        while count < target {
            guard signal.wait(timeout: deadline) == .success else { return false }
        }
        return true
    }
}

/// Timed one-byte round trips through `session`: write, echo, parse, grid.
/// Timed-out requests are counted, never sampled. With
/// `abortAfterConsecutiveTimeouts`, that many failures in a row means the
/// session or the PTY is wedged, not slow, and the run stops with what it
/// has rather than sit through the rest.
func measureEchoRoundTrips(
    _ session: TerminalSession, counter: EchoCounter, iterations: Int, abortAfterConsecutiveTimeouts: Int?
) -> (samples: [UInt64], submitted: Int, timedOut: Int, aborted: Bool) {
    // Warm up: the first write pays for thread startup and PTY buffering
    // effects a steady-state loop shouldn't be charged for.
    let warmupTarget = counter.count + 1
    session.write([UInt8(ascii: "a")])
    _ = counter.wait(until: warmupTarget, timeout: 1)

    var samples: [UInt64] = []
    samples.reserveCapacity(iterations)
    var submitted = 0
    var timedOut = 0
    var consecutiveTimeouts = 0
    for i in 0..<iterations {
        // Cycle through a few scalars so the grid write is not a no-op
        // fast path repeating the exact same cell every time.
        let byte = UInt8(ascii: "a") + UInt8(i % 26)
        let target = counter.count + 1
        let start = DispatchTime.now()
        session.write([byte])
        submitted += 1
        if counter.wait(until: target, timeout: 1) {
            samples.append(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds)
            consecutiveTimeouts = 0
            continue
        }
        timedOut += 1
        consecutiveTimeouts += 1
        // Resync: give the outstanding echo a grace window to land, so the
        // next request's submission snapshot already contains it and it
        // cannot be attributed to that request. A genuinely lost echo needs
        // no handling — every target is recomputed from the live count.
        _ = counter.wait(until: counter.count + 1, timeout: 0.2)
        if let limit = abortAfterConsecutiveTimeouts, consecutiveTimeouts >= limit {
            return (samples, submitted, timedOut, true)
        }
    }
    return (samples, submitted, timedOut, false)
}

