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
import Metal
import OSLog

/// Per-frame render timing in fixed-size buffers, summarised as
/// percentiles, so a before/after comparison is a log line. Pairs with
/// `InputLatencySignposts`: this says *that* something got slower, a trace
/// says *where*.
///
/// Gated by `CORTA_RENDER_METRICS`, a measurement harness rather than a
/// config key (D10), read once at start: disabled, each call costs one
/// Bool check. Any value turns it on; an absolute path also appends each
/// summary line to that file, which is how `MeasurementUITests` — a
/// sandboxed runner that cannot read the unified log — gets the numbers.
nonisolated enum RenderMetrics {
    enum Metric: String, CaseIterable {
        case drawableWait
        case cpuFrame
        case gpu
        /// HID timestamp → the first frame with the echo on the glass
        /// (`MTLDrawable.presentedTime`); see `noteKeystroke`.
        case keypressToPresent
    }

    static let isEnabled = ProcessInfo.processInfo.environment["CORTA_RENDER_METRICS"] != nil

    private static let outputFile: URL? = {
        guard let raw = ProcessInfo.processInfo.environment["CORTA_RENDER_METRICS"], raw.hasPrefix("/")
        else { return nil }
        return URL(fileURLWithPath: raw)
    }()

    private static let log = OSLog(subsystem: "dev.noahqin.Corta", category: "render-metrics")

    /// Samples per summary: ~10 s at 60 Hz.
    private static let capacity = 600
    /// 200 keystrokes, as earlier runs used; override with
    /// `CORTA_RENDER_METRICS_KEYSTROKES=<n>`.
    private static let keystrokeCapacity: Int = {
        let raw = ProcessInfo.processInfo.environment["CORTA_RENDER_METRICS_KEYSTROKES"] ?? ""
        if let n = Int(raw), n > 0 { return n }
        return 200
    }()

    private static let lock = NSLock()
    // Mutated only under `lock`; an actor would make render-path calls
    // `async`.
    nonisolated(unsafe) private static var samples: [Metric: [Double]] = [:]

    /// Records a sample; a full buffer is dumped and cleared, so a force-quit
    /// loses at most one window.
    static func record(_ metric: Metric, milliseconds: Double) {
        guard isEnabled else { return }
        lock.lock()
        var values = samples[metric, default: []]
        values.append(milliseconds)
        let full = values.count >= (metric == .keypressToPresent ? keystrokeCapacity : capacity)
        if full {
            samples[metric] = []
        } else {
            samples[metric] = values
        }
        lock.unlock()
        if full { dump(metric: metric, values: values) }
    }

    /// Times `body` when enabled; `body` always runs.
    @inline(__always)
    static func measure<T>(_ metric: Metric, _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        let start = DispatchTime.now()
        let result = body()
        let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        record(metric, milliseconds: elapsedMS)
        return result
    }

    private static func dump(metric: Metric, values: [Double]) {
        let sorted = values.sorted()
        let count = sorted.count
        let avg = values.reduce(0, +) / Double(count)
        let p50 = sorted[count / 2]
        let p95 = sorted[min(count - 1, Int(Double(count) * 0.95))]
        let p99 = sorted[min(count - 1, Int(Double(count) * 0.99))]
        let max = sorted[count - 1]
        os_log(
            "%{public}@: n=%{public}d avg=%{public}.2fms p50=%{public}.2fms p95=%{public}.2fms p99=%{public}.2fms max=%{public}.2fms",
            log: log, type: .default, metric.rawValue, count, avg, p50, p95, p99, max)
        if let outputFile {
            let line = String(
                format: "%@: n=%d avg=%.2fms p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms\n",
                metric.rawValue, count, avg, p50, p95, p99, max)
            append(line, to: outputFile)
        }
    }

    /// Once per full ring, never per frame; a failed write loses a line of
    /// measurement, which the reader reports as a ring that never filled.
    private static func append(_ line: String, to file: URL) {
        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    // MARK: - Keypress → glass

    /// One keystroke in flight. A newer one replaces one that never echoed;
    /// that sample is dropped, never guessed.
    private struct PendingKeystroke {
        var timestamp: TimeInterval
        var outputLanded = false
        /// Asks the pane for another frame (`TerminalView.setNeedsRedraw`).
        var requestFrame: @Sendable () -> Void
    }

    nonisolated(unsafe) private static var pending: PendingKeystroke?

    /// Called at `TerminalView`'s three delivery sites. `NSEvent.timestamp`
    /// shares `presentedTime`'s clock. Synthetic events are stamped at
    /// posting, missing the HID stage (`PERFORMANCE.md` §5.7).
    /// `requestFrame` wakes the pane when the echo's frame never reached
    /// the glass (see `notePresent`).
    static func noteKeystroke(at timestamp: TimeInterval, requestFrame: @escaping @Sendable () -> Void) {
        guard isEnabled else { return }
        lock.lock()
        pending = PendingKeystroke(timestamp: timestamp, requestFrame: requestFrame)
        lock.unlock()
    }

    /// A parse batch landed (reader thread); the first after a keystroke is
    /// taken as its echo.
    static func noteOutputForKeystroke() {
        guard isEnabled else { return }
        lock.lock()
        if pending != nil { pending?.outputLanded = true }
        lock.unlock()
    }

    /// Before presenting: if an echo is on the grid, this drawable's presented
    /// handler closes the sample when it is actually on screen.
    static func notePresent(of drawable: MTLDrawable) {
        guard isEnabled else { return }
        lock.lock()
        guard let keystroke = pending, keystroke.outputLanded else {
            lock.unlock()
            return
        }
        pending = nil
        lock.unlock()
        drawable.addPresentedHandler { presented in
            // Zero when the compositor replaced this drawable (about half a burst's
            // frames); re-pend rather than drop, which would flatter the number.
            // And ask for another frame: the echo was the last change, so the
            // display link parks, and without one the sample waits for the next
            // keystroke, which replaces it — under XCTest that lost five in six.
            guard presented.presentedTime > 0 else {
                lock.lock()
                let repended = pending == nil
                if repended { pending = keystroke }
                lock.unlock()
                if repended { keystroke.requestFrame() }
                return
            }
            let seconds = presented.presentedTime - keystroke.timestamp
            guard seconds >= 0, seconds < 2 else { return }
            record(.keypressToPresent, milliseconds: seconds * 1000)
        }
    }
}
