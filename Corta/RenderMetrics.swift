import Foundation
import Metal
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
/// should be setting (`docs/DECISIONS.md` D10). `isEnabled` is read once at process
/// start; every call site below checks the cached value, so a normal run
/// pays one Bool comparison per call and nothing else.
nonisolated enum RenderMetrics {
    enum Metric: String, CaseIterable {
        case drawableWait
        case cpuFrame
        case gpu
        /// Key event (its HID timestamp) → the first frame carrying the
        /// child's echo *on the glass* (`MTLDrawable.presentedTime`). The
        /// end-to-end number the README quotes, measured from inside the
        /// process — see `noteKeystroke`.
        case keypressToPresent
    }

    static let isEnabled = ProcessInfo.processInfo.environment["CORTA_RENDER_METRICS"] != nil

    private static let log = OSLog(subsystem: "dev.noahqin.Corta", category: "render-metrics")

    /// How many samples to keep per metric before summarising and starting
    /// over — 600 is ~10 s of frames at 60 Hz, long enough to smooth out one
    /// keystroke burst without holding an unbounded array.
    private static let capacity = 600
    /// Keystrokes arrive at typing speed, not frame rate: 200 is the sample
    /// size the Typometer runs used, and a person types it in a minute.
    /// `CORTA_RENDER_METRICS_KEYSTROKES=<n>` overrides it for a shorter run.
    private static let keystrokeCapacity: Int = {
        let raw = ProcessInfo.processInfo.environment["CORTA_RENDER_METRICS_KEYSTROKES"] ?? ""
        if let n = Int(raw), n > 0 { return n }
        return 200
    }()

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
        let full = values.count >= (metric == .keypressToPresent ? keystrokeCapacity : capacity)
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
        let p95 = sorted[min(count - 1, Int(Double(count) * 0.95))]
        let p99 = sorted[min(count - 1, Int(Double(count) * 0.99))]
        let max = sorted[count - 1]
        os_log(
            "%{public}@: n=%{public}d avg=%{public}.2fms p50=%{public}.2fms p95=%{public}.2fms p99=%{public}.2fms max=%{public}.2fms",
            log: log, type: .default, metric.rawValue, count, avg, p50, p95, p99, max)
    }

    // MARK: - Keypress → glass

    /// One keystroke in flight: its HID timestamp, and whether the child's
    /// echo has landed on the grid yet. A newer keystroke replaces an older
    /// one that never produced output (a modifier, a key the child
    /// swallowed) — the sample is dropped, never guessed.
    private struct PendingKeystroke {
        var timestamp: TimeInterval
        var outputLanded = false
    }

    nonisolated(unsafe) private static var pending: PendingKeystroke?

    /// Called where a key event turns into bytes for the child
    /// (`TerminalView`'s three delivery sites). `timestamp` is
    /// `NSEvent.timestamp` — seconds since boot, the same clock
    /// `MTLDrawable.presentedTime` reports on, so the two subtract. A
    /// synthetic event (`CGEventPost`, System Events) carries a timestamp
    /// too, but one minted at posting, so the HID stage is missing from a
    /// scripted run; `PERFORMANCE.md` §5.7 says which kind a number is.
    static func noteKeystroke(at timestamp: TimeInterval) {
        guard isEnabled else { return }
        lock.lock()
        pending = PendingKeystroke(timestamp: timestamp)
        lock.unlock()
    }

    /// Called from the reader thread when a parse batch lands on the grid.
    /// The first output after a keystroke is taken to be its echo — the
    /// same assumption a screen-capture tool makes ("the pixels changed
    /// after the key"); output that arrives with no keystroke pending is
    /// not a sample.
    static func noteOutputForKeystroke() {
        guard isEnabled else { return }
        lock.lock()
        if pending != nil { pending?.outputLanded = true }
        lock.unlock()
    }

    /// Called just before a drawable is presented. If a keystroke's echo is
    /// on the grid, this frame is the one that shows it: the drawable's
    /// presented handler — which fires when the frame is actually on
    /// screen, not when it was scheduled — closes the sample.
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
            // `presentedTime` is 0 when this drawable never reached the
            // glass — the compositor replaced it with the next one, which
            // happens for about half the frames a keystroke burst
            // produces. The echo is then shown by the *next* presented
            // drawable, so the keystroke goes back to pending rather than
            // being dropped: dropping it would keep only the frames that
            // were shown on the first try and flatter the number.
            guard presented.presentedTime > 0 else {
                lock.lock()
                if pending == nil { pending = keystroke }
                lock.unlock()
                return
            }
            let seconds = presented.presentedTime - keystroke.timestamp
            guard seconds >= 0, seconds < 2 else { return }
            record(.keypressToPresent, milliseconds: seconds * 1000)
        }
    }
}
