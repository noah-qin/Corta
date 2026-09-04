import Foundation
import OSLog

/// Aggregates per-frame render timing into fixed-size ring buffers so a
/// before/after comparison across a render-pipeline change is a log line,
/// not an Instruments session.
///
/// This is not a replacement for `InputLatencySignposts` — that is the
/// "emit" layer (one atomic load when disabled, Instruments-only). This is
/// the "collect and summarise" layer: a handful of doubles per metric,
/// dumped as percentiles once the buffer fills. The two are meant to be
/// read together — a `RenderMetrics` regression says *that* something got
/// slower; a signpost trace of the same run says *where*.
///
/// Gated by `CORTA_RENDER_METRICS` — a measurement harness like
/// `CORTA_MAX_DRAWABLES` (`TerminalView.swift`), not a config key nobody
/// should be setting (`CLAUDE.md`). `isEnabled` is read once at process
/// start; every call site below checks the cached value, so a normal run
/// pays one Bool comparison per call and nothing else.
nonisolated enum RenderMetrics {
    enum Metric: String, CaseIterable {
        case drawableWait
        case cpuFrame
        case gpu
    }

    static let isEnabled = ProcessInfo.processInfo.environment["CORTA_RENDER_METRICS"] != nil

    private static let log = OSLog(subsystem: "dev.noahqin.Corta", category: "render-metrics")

    /// How many samples to keep per metric before summarising and starting
    /// over — 600 is ~10 s of frames at 60 Hz, long enough to smooth out one
    /// keystroke burst without holding an unbounded array.
    private static let capacity = 600

    private static let lock = NSLock()
    // Mutated only under `lock`; Swift's static-isolation checker cannot see
    // that, so it is told explicitly rather than moved to an actor — an
    // actor would make every render-path call site `async`.
    nonisolated(unsafe) private static var samples: [Metric: [Double]] = [:]

    /// Records one timing sample in milliseconds. Dumps and clears that
    /// metric's buffer once it reaches `capacity`, so a long-running session
    /// prints a rolling series of summaries instead of one enormous one at
    /// exit (which a force-quit would lose entirely).
    static func record(_ metric: Metric, milliseconds: Double) {
        guard isEnabled else { return }
        lock.lock()
        var values = samples[metric, default: []]
        values.append(milliseconds)
        let full = values.count >= capacity
        if full {
            samples[metric] = []
        } else {
            samples[metric] = values
        }
        lock.unlock()
        if full { dump(metric: metric, values: values) }
    }

    /// Elapsed wall-clock time for `body`, recorded under `metric` if
    /// enabled. `body` still runs when disabled — only the timing call is
    /// skipped — so this is safe to wrap around code that must always run.
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
        let p99 = sorted[min(count - 1, Int(Double(count) * 0.99))]
        let max = sorted[count - 1]
        os_log(
            "%{public}@: n=%{public}d avg=%{public}.2fms p50=%{public}.2fms p99=%{public}.2fms max=%{public}.2fms",
            log: log, type: .default, metric.rawValue, count, avg, p50, p99, max)
    }
}
