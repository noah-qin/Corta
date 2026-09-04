import AppKit
import QuartzCore

/// Adapts a pane's `CAMetalDisplayLink` frame-rate ceiling to window focus,
/// Low Power Mode, thermal pressure, and an active scroll gesture.
///
/// This sits entirely on top of `FrameScheduler`'s `isPaused` gate, which
/// already takes idle CPU to ~0% on its own and is unaffected by anything
/// here (`PERFORMANCE.md` §3): `RenderPolicy` only ever widens or narrows
/// the gap between wakeups on a link that is already running, deciding
/// nothing about whether to render a given frame at all — that stays
/// `ViewController.prepareFrame`'s job. A window that never redraws pays
/// nothing for any of this; a window that is continuously producing output
/// (a flooding build log) while occluded, backgrounded, thermally
/// throttled, or on battery in Low Power Mode is the case this exists for.
///
/// **`preferredFrameLatency` is deliberately untouched.** The plan this
/// milestone came from called for lowering it while typing, for tighter
/// input latency. `CAMetalDisplayLink.preferredFrameLatency` is a bare
/// `Float` with no documented default constant or unit guidance in the
/// SDK header (`CAMetalDisplayLink.h`) beyond "how far ahead of the
/// deadline to run" — picking a number without a measurement to justify it
/// risks the opposite of the intended effect (running the callback too
/// early relative to a frame that is not actually ready), and this
/// milestone's own instrumentation (`RenderMetrics`, `InputLatencySignposts`)
/// exists specifically so a change like that is chosen from a number, not
/// a guess (`PERFORMANCE.md` §5.3-5.4's stated approach). Left for a
/// follow-up once there is a keypress-to-pixel trace to tune it against.
final class RenderPolicy {
    private weak var scheduler: FrameScheduler?
    private weak var window: NSWindow?
    // `nonisolated(unsafe)`: read from `deinit`, which runs nonisolated even
    // on this MainActor-isolated class — `NotificationCenter.removeObserver`
    // is thread-safe, matching `TerminalView.occlusionObserver`'s reasoning.
    nonisolated(unsafe) private var thermalObserver: NSObjectProtocol?
    nonisolated(unsafe) private var powerStateObserver: NSObjectProtocol?
    nonisolated(unsafe) private var keyObserver: NSObjectProtocol?
    nonisolated(unsafe) private var resignObserver: NSObjectProtocol?
    private var isWindowActive: Bool
    private var isScrolling = false

    /// Frame-rate ceilings, in ascending order of restriction below. Never
    /// zero: a restricted window still has to redraw *something* when its
    /// content changes (a background build finishing), just not at the
    /// display's full rate. Deliberately modest rather than tuned to a
    /// specific number — like `preferredFrameLatency` above, the exact
    /// values are a candidate for the same measurement pass, not a
    /// guess to be trusted blind.
    private static let unrestricted = CAFrameRateRange.default
    private static let inactiveWindow = CAFrameRateRange(minimum: 1, maximum: 30, preferred: 15)
    private static let lowPower = CAFrameRateRange(minimum: 1, maximum: 30, preferred: 15)
    private static let thermalPressure = CAFrameRateRange(minimum: 1, maximum: 20, preferred: 10)

    /// - Parameter window: observed for key/resign to track focus; weak,
    ///   like `scheduler` — this outlives neither.
    init(scheduler: FrameScheduler, window: NSWindow?) {
        self.scheduler = scheduler
        self.window = window
        self.isWindowActive = window?.isKeyWindow ?? true

        let center = NotificationCenter.default
        thermalObserver = center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        powerStateObserver = center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        if let window {
            keyObserver = center.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowActiveStateChanged(true) }
            }
            resignObserver = center.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowActiveStateChanged(false) }
            }
        }
        apply()
    }

    deinit {
        let center = NotificationCenter.default
        if let thermalObserver { center.removeObserver(thermalObserver) }
        if let powerStateObserver { center.removeObserver(powerStateObserver) }
        if let keyObserver { center.removeObserver(keyObserver) }
        if let resignObserver { center.removeObserver(resignObserver) }
    }

    private func windowActiveStateChanged(_ isActive: Bool) {
        isWindowActive = isActive
        apply()
    }

    /// Called from `TerminalView.scrollWheel(with:)` on a trackpad gesture's
    /// phase transitions (`NSEvent.phase`/`momentumPhase`) — a plain mouse
    /// wheel carries no phase and so never raises this, which only costs
    /// this one enhancement for that input device, not correctness: the
    /// policy simply never restricts the rate *while* such a wheel is
    /// spinning, same as it wouldn't need to for a single notch at a time.
    func scrollingStateChanged(_ scrolling: Bool) {
        guard isScrolling != scrolling else { return }
        isScrolling = scrolling
        apply()
    }

    private func apply() {
        guard let scheduler else { return }
        // Highest priority first: scrolling wants the full rate so the
        // motion reads as smooth, regardless of what else is going on —
        // even a thermally-throttled machine should not turn a scroll
        // gesture choppy if it can still drive the display's full rate for
        // the couple of seconds a gesture actually lasts.
        if isScrolling {
            scheduler.preferredFrameRateRange = Self.unrestricted
            return
        }
        let info = ProcessInfo.processInfo
        if info.thermalState == .serious || info.thermalState == .critical {
            scheduler.preferredFrameRateRange = Self.thermalPressure
        } else if info.isLowPowerModeEnabled {
            scheduler.preferredFrameRateRange = Self.lowPower
        } else if !isWindowActive {
            scheduler.preferredFrameRateRange = Self.inactiveWindow
        } else {
            scheduler.preferredFrameRateRange = Self.unrestricted
        }
    }
}
