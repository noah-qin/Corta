import AppKit
import Metal
import QuartzCore

/// Owns the vsync-to-drawable pipeline for one `TerminalView`'s Metal layer,
/// through `CAMetalDisplayLink`.
///
/// **Why nothing is asked before the drawable.** With a `CADisplayLink`,
/// vsync and drawable acquisition are separate, and the "should I draw?"
/// check has to run *before* `nextDrawable()` — an acquired-but-unpresented
/// drawable is not recycled, so acquiring one per skipped frame would
/// exhaust the pool. `CAMetalDisplayLink` folds vsync and drawable
/// acquisition into one delegate callback that already carries the
/// resolved drawable (`CAMetalDisplayLink.Update.drawable`) — there is no
/// separate acquire step to skip ahead of.
///
/// **The rule instead.** `isPaused` is the only gate. While paused, the
/// link never fires, so nothing is ever asked and no drawable is ever
/// resolved — this is what keeps idle CPU at ~0% (`PERFORMANCE.md` §3). A
/// caller wakes the scheduler only when there is a concrete
/// reason to draw (`resume()`); every callback that *does* fire is treated
/// as accepted — its drawable is always rendered and presented, never
/// discarded — and the scheduler pauses itself again the moment a frame
/// finds nothing further pending. This trades a rare, harmless
/// re-presentation of unchanged pixels (a spurious wake with nothing new by
/// the time the callback runs) for never leaving a resolved drawable
/// unpresented, which is what would exhaust the pool.
final class FrameScheduler: NSObject, CAMetalDisplayLinkDelegate {
    /// Called once per accepted frame, on the main thread, with the
    /// already-resolved drawable and its render pass descriptor. There is
    /// no `nil`-drawable case —
    /// the delegate only fires when `CAMetalDisplayLink` already has one.
    var onRenderFrame: ((MTLRenderPassDescriptor, CGSize, CAMetalDrawable) -> Void)?

    /// Run once per accepted frame, before rendering, to do the prepare/diff
    /// work (grid snapshot, damage check, and their side effects) and report
    /// whether anything is still pending. A resolved drawable is rendered
    /// and presented either way; the return value only decides whether the
    /// scheduler pauses itself right after — `false` means "nothing left to
    /// draw," though it cannot skip the drawable itself.
    var shouldRenderFrame: (() -> Bool)?

    private let metalLayer: CAMetalLayer
    private var link: CAMetalDisplayLink?
    /// Survives `attach(to:)` recreating `link` (a window change) — without
    /// this, moving a tab to a new window would silently drop back to the
    /// full, unrestricted rate regardless of what `RenderPolicy` had set.
    private var desiredFrameRateRange = CAFrameRateRange.default
    /// Where the flash-guard request (`requestFirstPresent`) stands.
    /// Stored, not derived: the stand-in `backgroundColor` must stay on the
    /// layer until a frame has actually been presented, however the window
    /// is closed, re-shown or resized in between.
    private(set) var firstPresentState: FirstPresentState = .idle

    init(metalLayer: CAMetalLayer) {
        self.metalLayer = metalLayer
        super.init()
    }

    /// (Re)creates the display link against the given window, invalidating
    /// any previous one. Follows `TerminalView.viewDidMoveToWindow`: a `nil`
    /// window tears the link down.
    func attach(to window: NSWindow?) {
        link?.invalidate()
        guard window != nil else {
            link = nil
            return
        }
        let newLink = CAMetalDisplayLink(metalLayer: metalLayer)
        newLink.delegate = self
        newLink.add(to: .main, forMode: .common)
        newLink.isPaused = true
        newLink.preferredFrameRateRange = desiredFrameRateRange
        // Measurement hook, same class as `CORTA_MAX_DRAWABLES`
        // (`TerminalView.commonInit`): `preferredFrameLatency`, in frames,
        // is a value to pick from an A/B measurement, not a guess
        // (`RenderPolicy`'s doc comment) — an environment variable, not a config key, and never read
        // outside one. `RenderPolicy` manages only `preferredFrameRateRange`,
        // so nothing fights this once set at attach.
        if let raw = ProcessInfo.processInfo.environment["CORTA_FRAME_LATENCY"],
            let latency = Float(raw), latency >= 1
        {
            newLink.preferredFrameLatency = latency
        }
        link = newLink
    }

    /// Wakes the scheduler so the next vsync's callback actually renders.
    /// Idempotent, main-thread only, like everything else here.
    func resume() {
        link?.isPaused = false
    }

    var isPaused: Bool {
        get { link?.isPaused ?? true }
        set { link?.isPaused = newValue }
    }

    /// The vsync rate ceiling, adapted by `RenderPolicy` to window focus,
    /// Low Power Mode, thermal pressure and active scrolling. Lowering it
    /// only widens the gap between wakeups on a link that is already
    /// running — it has no effect on `isPaused`, which is what actually
    /// decides whether the link fires at all (`PERFORMANCE.md` §3).
    var preferredFrameRateRange: CAFrameRateRange {
        get { desiredFrameRateRange }
        set {
            desiredFrameRateRange = newValue
            link?.preferredFrameRateRange = newValue
        }
    }

    /// Arms the first-present flash guard and returns immediately — used to
    /// paint before the window is ordered on screen, and after a live theme
    /// change. It never pumps the main run loop to wait for a frame: a
    /// synchronous wait here is reentrant, and every timer, delegate and
    /// second `drawNow` the loop services runs nested inside what looks
    /// like a leaf call.
    ///
    /// So this is an explicit state transition, not a wait. The
    /// window needs no pixel-perfect first frame, only a guarantee it never
    /// shows what is behind it: the layer's `backgroundColor` is set to the
    /// theme's clear colour — exactly what the first frame's render pass
    /// clears to — and the link is resumed so the real frame lands at the
    /// next vsync. `notePresentedFrame` then retires the stand-in. `nil`
    /// link (view not yet in a window) just means the state outlives the
    /// attach; the first frame after the next `attach(to:)` completes it.
    func requestFirstPresent() {
        let bg = TerminalColorPalette.clearColor
        metalLayer.backgroundColor = CGColor(
            red: CGFloat(bg.x), green: CGFloat(bg.y), blue: CGFloat(bg.z),
            alpha: CGFloat(bg.w))
        firstPresentState = .awaitingFrame
        link?.isPaused = false
    }

    /// The first frame's command buffer has been committed and its drawable
    /// scheduled for presentation — which is not the same as the frame
    /// being on the glass. The GPU still has to run it and the compositor
    /// still has to pick it up, and stripping the stand-in in the same
    /// transaction left one compositor frame with a layer that had neither
    /// a background nor contents: a transparent window, the desktop showing
    /// through for a sixtieth of a second, on every reopen (found on a
    /// screen recording of the Dock-click path, frame by frame). So the
    /// stand-in stays up for one more display-link tick, and the *next*
    /// callback — by which time the first drawable has been on screen for
    /// a whole frame — retires it.
    func noteFrameSubmitted() {
        guard firstPresentState == .awaitingFrame else { return }
        firstPresentState = .submitted
    }

    /// The transition to `.idle`, run once the first frame is actually on
    /// the glass. Called from `metalDisplayLink(_:needsUpdate:)` on the tick
    /// after the one that submitted the frame — and directly by tests,
    /// since driving a real `CAMetalDisplayLink` needs a visible window and
    /// a turning run loop. A no-op in `.idle`, so a stray callback can never
    /// strip a stand-in a *newer* request just armed.
    func notePresentedFrame() {
        guard firstPresentState != .idle else { return }
        firstPresentState = .idle
        metalLayer.backgroundColor = nil
    }

    func metalDisplayLink(
        _ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update
    ) {
        let frameInterval = InputLatencySignposts.begin(.frame)
        defer { InputLatencySignposts.end(.frame, frameInterval) }
        let frameStart = RenderMetrics.isEnabled ? DispatchTime.now() : nil
        defer {
            if let frameStart {
                let ms =
                    Double(DispatchTime.now().uptimeNanoseconds - frameStart.uptimeNanoseconds)
                    / 1_000_000
                RenderMetrics.record(.cpuFrame, milliseconds: ms)
            }
        }
        // There is no explicit acquire call left to time (the drawable
        // above is already resolved), so the closest available signal for
        // "how late did this frame run" is how far past its own target
        // timestamp `CAMetalDisplayLink` actually invoked us — the same
        // stalling `PERFORMANCE.md` §5.3/§5.4 measured via
        // `CAMetalLayer.Stalls` would show up here as a growing gap.
        if RenderMetrics.isEnabled {
            let latenessMS = (CACurrentMediaTime() - update.targetTimestamp) * 1000
            RenderMetrics.record(.drawableWait, milliseconds: max(0, latenessMS))
        }
        let stillPending = shouldRenderFrame?() ?? true
        // The frame submitted on the previous tick is on the glass now;
        // the stand-in behind it can go (`noteFrameSubmitted`).
        let retiringStandIn = firstPresentState == .submitted
        if retiringStandIn { notePresentedFrame() }
        let drawable = update.drawable
        if let onRenderFrame {
            onRenderFrame(FrameScheduler.clearPass(for: drawable), metalLayer.drawableSize, drawable)
            noteFrameSubmitted()
        }
        // One more tick is owed while a stand-in is still up, even with
        // nothing else to draw: pausing here would leave it in place until
        // the next unrelated frame — harmless, but then the retirement
        // would ride on output rather than on time.
        if !stillPending && firstPresentState != .submitted {
            link.isPaused = true
        }
    }

    /// A render pass that clears to the theme's background colour.
    private static func clearPass(for drawable: CAMetalDrawable) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        let bg = TerminalColorPalette.clearColor
        pass.colorAttachments[0].clearColor = MTLClearColorMake(
            Double(bg.x), Double(bg.y), Double(bg.z), Double(bg.w))
        pass.colorAttachments[0].storeAction = .store
        return pass
    }
}

/// The flash-guard state machine — see `FrameScheduler.requestFirstPresent`.
enum FirstPresentState: Equatable {
    /// Nothing outstanding; the layer shows whatever was last presented.
    case idle
    /// A first frame was requested but not yet presented; until it is, the
    /// layer's `backgroundColor` (the theme's clear colour) stands in so the
    /// transparent window can never show what is behind it.
    case awaitingFrame
    /// The first frame's drawable has been scheduled but has not had a
    /// display-link tick to reach the glass; the stand-in stays up until the
    /// next tick (`FrameScheduler.noteFrameSubmitted`).
    case submitted
}
