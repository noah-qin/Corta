import Darwin
import Foundation
import OSLog

/// `os_signpost` across the whole keypress-to-pixel chain, so the number in
/// `docs/PERFORMANCE.md` §1 can be attributed instead of only measured.
///
/// **The gap this closes.** M6.12 measured 45.5 ms keypress-to-pixel with
/// Typometer, and `corta-bench` measures the core half of it — but between
/// them there was nothing that said *where* the 45 ms goes. A one-number
/// end-to-end measurement can only ever tell you whether the last change
/// helped; it cannot tell you that a regression is in the parse, in the
/// MainActor hop, in waiting for a drawable, or in the GPU, and every one of
/// those has a different fix. The frame-CPU regression the project's own
/// rules warn about (2.40 ms → 4.19 ms, invisible to every passing test) is
/// exactly the class of thing an attributed trace finds in one pass.
///
/// **The chain**, in order, with the signpost each stage emits:
///
/// | Stage | Interval | Where |
/// | --- | --- | --- |
/// | key event → bytes on the PTY | `keyDown` | `TerminalView.deliverBytes` |
/// | reader wakes, parses, writes the grid | `output` | `ViewController.noteOutput` |
/// | MainActor hop that wakes the display link | `wake` | `ViewController.noteOutput` |
/// | vsync callback, damage diff, instance build | `frame` | `FrameScheduler.metalDisplayLink(_:needsUpdate:)` |
/// | encode + commit | `commit` | `ViewController.render` |
/// | GPU work through to completion | `gpu` | `ViewController.render` |
///
/// **Cost when nothing is listening.** `OSSignposter.isEnabled` is false
/// unless a trace is being recorded, and every call here is behind it — so
/// the render path pays one atomic load per stage, which is what makes this
/// safe to leave in a release build (`PERFORMANCE.md` §2: no per-frame
/// allocation, no ObjC bridging on the hot path).
///
/// **How to record one.** With Instruments' "os_signpost" instrument, or:
///
/// ```sh
/// xcrun xctrace record --template 'os_signpost' --launch -- \
///     /path/to/Corta.app/Contents/MacOS/Corta
/// ```
///
/// Then filter on subsystem `dev.noahqin.Corta`, category `input-latency`.
/// `nonisolated`: the chain crosses threads by design — `keyDown` is on the
/// main thread, `output` is on the reader thread — so nothing here may be
/// actor-bound. `OSSignposter` is itself thread-safe.
nonisolated enum InputLatencySignposts {
    static let subsystem = "dev.noahqin.Corta"
    static let category = "input-latency"

    /// One signposter for the process. `OSLog(subsystem:category:)` is the
    /// signpost-capable initialiser; the `Logger`-style one is not.
    static let signposter = OSSignposter(
        logHandle: OSLog(subsystem: subsystem, category: category))

    /// Whether a trace is being recorded. Checked at every call site so a
    /// normal run does no work at all.
    static var isEnabled: Bool { signposter.isEnabled }

    /// The signpost API takes a `StaticString` name, which cannot be an
    /// enum's raw value (`StaticString` is not `Equatable`). So each stage
    /// carries its literal in a computed property instead — the literal is
    /// still static, which is what the API actually requires.
    enum Stage {
        case keyDown
        case output
        case wake
        case frame
        case commit
        case gpu

        var name: StaticString {
            switch self {
            case .keyDown: "keyDown"
            case .output: "output"
            case .wake: "wake"
            case .frame: "frame"
            case .commit: "commit"
            case .gpu: "gpu"
            }
        }
    }

    /// Begins an interval, or returns nil when no trace is running.
    static func begin(_ stage: Stage) -> OSSignpostIntervalState? {
        guard isEnabled else { return nil }
        return signposter.beginInterval(stage.name, id: signposter.makeSignpostID())
    }

    static func end(_ stage: Stage, _ state: OSSignpostIntervalState?) {
        guard let state else { return }
        signposter.endInterval(stage.name, state)
    }

    /// A single point in time rather than an interval — for the hand-offs
    /// where the two ends run on different threads and an interval would have
    /// to be carried across them.
    static func emit(_ stage: Stage) {
        guard isEnabled else { return }
        signposter.emitEvent(stage.name, id: signposter.makeSignpostID())
    }

    /// Wraps `body` in an interval. The closure form so a call site cannot
    /// forget the `end` on an early return.
    @inline(__always)
    static func measure<T>(_ stage: Stage, _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        let state = begin(stage)
        defer { end(stage, state) }
        return body()
    }
}
