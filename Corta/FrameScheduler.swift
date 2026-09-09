import AppKit
import Metal
import QuartzCore

/// Owns the vsync-to-drawable pipeline for one `TerminalView`'s Metal layer:
/// `CAMetalDisplayLink` in place of the old `CADisplayLink` +
/// `metalLayer.nextDrawable()` split.
///
/// **Why the old ordering doesn't carry over.** `CADisplayLink` only signals
/// vsync; a drawable is acquired separately, so the old code asked
/// `shouldRenderFrame` *before* calling `nextDrawable()` — deliberately, an
/// acquired-but-unpresented drawable is not recycled, so acquiring one per
/// skipped frame would exhaust the pool. `CAMetalDisplayLink` folds vsync and
/// drawable acquisition into one delegate callback that already carries the
/// resolved drawable (`CAMetalDisplayLink.Update.drawable`) — there is no
/// separate acquire step left to skip ahead of.
///
/// **The replacement rule.** `isPaused` is the only gate. While paused, the
/// link never fires, so nothing is ever asked and no drawable is ever
/// resolved — this is what keeps idle CPU at ~0% (`PERFORMANCE.md` §3), same
/// as before. A caller wakes the scheduler only when there is a concrete
/// reason to draw (`resume()`); every callback that *does* fire is treated
/// as accepted — its drawable is always rendered and presented, never
/// discarded — and the scheduler pauses itself again the moment a frame
/// finds nothing further pending. This trades a rare, harmless
/// re-presentation of unchanged pixels (a spurious wake with nothing new by
/// the time the callback runs) for never leaving a resolved drawable
/// unpresented, which is the failure mode the old ordering was guarding
/// against in the first place.
final class FrameScheduler: NSObject, CAMetalDisplayLinkDelegate {
    /// Called once per accepted frame, on the main thread, with the
    /// already-resolved drawable and its render pass descriptor. Unlike the
    /// old `TerminalView.onRenderFrame`, there is no `nil`-drawable case —
    /// the delegate only fires when `CAMetalDisplayLink` already has one.
    var onRenderFrame: ((MTLRenderPassDescriptor, CGSize, CAMetalDrawable) -> Void)?

    /// Run once per accepted frame, before rendering, to do the prepare/diff
    /// work (grid snapshot, damage check, and their side effects) and report
    /// whether anything is still pending. A resolved drawable is rendered
    /// and presented either way; the return value only decides whether the
    /// scheduler pauses itself right after — `false` means "nothing left to
    /// draw," matching the old `shouldRenderFrame`'s meaning even though it
    /// can no longer skip the drawable itself.
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
    /// any previous one. Mirrors the old `TerminalView.viewDidMoveToWindow`
    /// lifecycle: `nil` window tears the link down.
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
    /// change. The old `presentSynchronously` instead resumed the link and
    /// pumped the main run loop for up to 0.5 s with a swapped-in
    /// `onRenderFrame` wrapper: bounded, but reentrant — every timer,
    /// delegate and second `drawNow` the loop serviced ran nested inside
    /// what looked like a leaf call (E05).
    ///
    /// The replacement is an explicit state transition, not a wait. The
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

    /// The transition out of `.awaitingFrame`, run only after a frame has
    /// actually been rendered and presented. Called from
    /// `metalDisplayLink(_:needsUpdate:)` — and directly by tests, since
    /// driving a real `CAMetalDisplayLink` needs a visible window and a
    /// turning run loop. A no-op in `.idle`, so a stray callback can never
    /// strip a stand-in a *newer* request just armed.
    func notePresentedFrame() {
        guard firstPresentState == .awaitingFrame else { return }
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
        let drawable = update.drawable
        if let onRenderFrame {
            onRenderFrame(FrameScheduler.clearPass(for: drawable), metalLayer.drawableSize, drawable)
            // The frame is presented (the handler presents synchronously),
            // so the first-present stand-in — if armed — is now redundant.
            notePresentedFrame()
        }
        if !stillPending {
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

/// The flash-guard state machine (E05) — see `FrameScheduler.requestFirstPresent`.
enum FirstPresentState: Equatable {
    /// Nothing outstanding; the layer shows whatever was last presented.
    case idle
    /// A first frame was requested but not yet presented; until it is, the
    /// layer's `backgroundColor` (the theme's clear colour) stands in so the
    /// transparent window can never show what is behind it.
    case awaitingFrame
}
