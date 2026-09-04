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

    /// Forces one frame to render and present before returning — used only
    /// to avoid a transparent-window flash before the window is shown, and
    /// after a live theme change. `CAMetalDisplayLink` has no synchronous
    /// "render one frame now" call of its own, and calling
    /// `metalLayer.nextDrawable()` directly once a `CAMetalDisplayLink` owns
    /// the layer raises `CAMetalLayerInvalidOperation` — Metal does not
    /// allow mixing the two ways of getting a drawable on the same layer.
    /// So this resumes the link and pumps the run loop — the same mechanism
    /// the link already uses to deliver its callback — until that callback
    /// has actually fired, or a generous timeout elapses and it gives up
    /// silently (this is a best-effort flash guard, not a correctness
    /// requirement worth hanging over).
    func presentSynchronously(timeout: TimeInterval = 0.5) {
        guard let link else { return }
        var rendered = false
        let previousHandler = onRenderFrame
        onRenderFrame = { pass, size, drawable in
            previousHandler?(pass, size, drawable)
            rendered = true
        }
        link.isPaused = false
        let deadline = Date().addingTimeInterval(timeout)
        // `.common` (used to *schedule* the link, above) is a mode-set
        // marker, not a mode the run loop can actually be run in — running
        // it here needs one real mode from that set, and `.default` is the
        // one the link always participates in.
        while !rendered && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        onRenderFrame = previousHandler
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
        onRenderFrame?(FrameScheduler.clearPass(for: drawable), metalLayer.drawableSize, drawable)
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
