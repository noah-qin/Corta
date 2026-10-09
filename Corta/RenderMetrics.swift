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
import Synchronization

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
        case wakeHop
        case callbackLead
        /// Presentation lead on the first tick after a paused link resumes.
        case firstAfterResume
        case resumeToCallback
        case frameInterval
        case drawableWait
        case cpuFrame
        case gpu
        /// HID timestamp → the first frame with the echo on the glass
        /// (`MTLDrawable.presentedTime`); see `noteKeystroke`.
        case keypressToPresent
    }

    static let isEnabled = DiagnosticsEnvironment.isRenderMetricsEnabled()

    private static let outputFile = DiagnosticsEnvironment.renderMetricsFile()

    private static let log = OSLog(subsystem: "dev.noahqin.Corta", category: "render-metrics")

    /// Samples per summary: ~10 s at 60 Hz.
    private static let capacity = 600
    /// 200 keystrokes, as earlier runs used; override with
    /// `CORTA_RENDER_METRICS_KEYSTROKES=<n>`.
    private static let keystrokeCapacity = DiagnosticsEnvironment.renderMetricsKeystrokes() ?? 200

    /// The samples and the pending keystroke, behind one lock; an actor would
    /// make render-path calls `async`. The summary file has its own.
    private struct State {
        var samples: [Metric: [Double]] = [:]
        var pending: PendingKeystroke?
        var conditions: Conditions?
    }

    private struct Conditions: Sendable {
        var minimum: Float
        var maximum: Float
        var preferred: Float?
        var lowPower: Bool

        var description: String {
            "rate=\(minimum)/\(maximum)/\(preferred.map { String($0) } ?? "default")Hz lowPower=\(lowPower)"
        }
    }

    private static let state = Mutex(State())
    /// Serialises appends to `outputFile`; held only for the write, never
    /// with `state`.
    private static let fileLock = Mutex(())

    /// Records a sample; a full buffer is dumped and cleared, so a force-quit
    /// loses at most one window.
    static func record(_ metric: Metric, milliseconds: Double) {
        guard isEnabled else { return }
        let full: [Double]? = state.withLock { state in
            // In place: a copy out of the dictionary would copy the ring per
            // sample.
            state.samples[metric, default: []].append(milliseconds)
            let limit: Int
            switch metric {
            case .keypressToPresent, .wakeHop, .callbackLead, .firstAfterResume, .resumeToCallback, .frameInterval:
                limit = keystrokeCapacity
            case .drawableWait, .cpuFrame, .gpu:
                limit = capacity
            }
            guard let values = state.samples[metric], values.count >= limit else { return nil }
            state.samples[metric] = []
            return values
        }
        if let full { dump(metric: metric, values: full) }
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

    static func noteConditions(minimum: Float, maximum: Float, preferred: Float?, lowPower: Bool) {
        guard isEnabled else { return }
        state.withLock {
            $0.conditions = Conditions(minimum: minimum, maximum: maximum, preferred: preferred, lowPower: lowPower)
        }
    }

    private static func dump(metric: Metric, values: [Double]) {
        let sorted = values.sorted()
        let count = sorted.count
        let avg = values.reduce(0, +) / Double(count)
        let p50 = sorted[count / 2]
        let p95 = sorted[min(count - 1, Int(Double(count) * 0.95))]
        let p99 = sorted[min(count - 1, Int(Double(count) * 0.99))]
        let max = sorted[count - 1]
        let conditions = state.withLock { $0.conditions }?.description ?? "conditions=unavailable"
        os_log(
            "%{public}@: n=%{public}d avg=%{public}.2fms p50=%{public}.2fms p95=%{public}.2fms p99=%{public}.2fms max=%{public}.2fms %{public}@",
            log: log, type: .default, metric.rawValue, count, avg, p50, p95, p99, max, conditions)
        if let outputFile {
            let line = String(
                format: "%@: n=%d avg=%.2fms p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms %@\n",
                metric.rawValue, count, avg, p50, p95, p99, max, conditions)
            append(line, to: outputFile)
        }
    }

    /// Once per full ring, never per frame; a failed write loses a line of
    /// measurement, which the reader reports as a ring that never filled.
    private static func append(_ line: String, to file: URL) {
        fileLock.withLock { _ in write(line, to: file) }
    }

    private static func write(_ line: String, to file: URL) {
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
    private struct PendingKeystroke: Sendable {
        var timestamp: TimeInterval
        var outputLanded = false
        /// Asks the pane for another frame (`TerminalView.setNeedsRedraw`).
        var requestFrame: @Sendable () -> Void
    }

    /// Called at `TerminalView`'s three delivery sites. `NSEvent.timestamp`
    /// shares `presentedTime`'s clock. Synthetic events are stamped at
    /// posting, missing the HID stage (`PERFORMANCE.md` §5.7).
    /// `requestFrame` wakes the pane when the echo's frame never reached
    /// the glass (see `notePresent`).
    static func noteKeystroke(at timestamp: TimeInterval, requestFrame: @escaping @Sendable () -> Void) {
        guard isEnabled else { return }
        state.withLock { $0.pending = PendingKeystroke(timestamp: timestamp, requestFrame: requestFrame) }
    }

    /// A parse batch landed (reader thread); the first after a keystroke is
    /// taken as its echo.
    static func noteOutputForKeystroke() {
        guard isEnabled else { return }
        state.withLock { $0.pending?.outputLanded = true }
    }

    /// Before presenting: if an echo is on the grid, this drawable's presented
    /// handler closes the sample when it is actually on screen.
    static func notePresent(of drawable: MTLDrawable) {
        guard isEnabled else { return }
        let landed: PendingKeystroke? = state.withLock { state in
            guard let keystroke = state.pending, keystroke.outputLanded else { return nil }
            state.pending = nil
            return keystroke
        }
        guard let keystroke = landed else { return }
        drawable.addPresentedHandler { presented in
            // Zero when the compositor replaced this drawable (about half a burst's
            // frames); re-pend rather than drop, which would flatter the number.
            // And ask for another frame: the echo was the last change, so the
            // display link parks, and without one the sample waits for the next
            // keystroke, which replaces it — under XCTest that lost five in six.
            guard presented.presentedTime > 0 else {
                let repended = state.withLock { state in
                    guard state.pending == nil else { return false }
                    state.pending = keystroke
                    return true
                }
                if repended { keystroke.requestFrame() }
                return
            }
            let seconds = presented.presentedTime - keystroke.timestamp
            guard seconds >= 0, seconds < 2 else { return }
            record(.keypressToPresent, milliseconds: seconds * 1000)
        }
    }
}
