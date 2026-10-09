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

import AppKit
import Metal
import QuartzCore

/// Owns one `TerminalView`'s presentation pipeline. The default
/// `CAMetalDisplayLink` carries a resolved drawable; the opt-in echo
/// experiment uses `CADisplayLink` pacing and acquires its own drawable.
///
/// **The rule.** `isPaused` is the only gate: paused, nothing fires, which
/// keeps idle CPU near 0% (`PERFORMANCE.md` §3). `resume()` wakes it for a
/// concrete reason; every callback that fires renders and presents its
/// drawable, never discards it (an unpresented drawable is never recycled),
/// and the scheduler pauses once nothing is pending. A spurious wake costs
/// at most one re-presentation of unchanged pixels.
final class FrameScheduler: NSObject, CAMetalDisplayLinkDelegate {
    /// Called per accepted frame on the main thread with the drawable size
    /// and the resolved drawable, which the callee must present. Returns
    /// whether the frame was drawn: a dropped frame (`Metal4Backend`) was
    /// presented with stale contents and is owed another tick.
    var onRenderFrame: ((CGSize, CAMetalDrawable) -> Bool)?

    /// The per-frame prepare/diff work; returns whether anything is still
    /// pending. The drawable is presented either way; `false` only pauses.
    var shouldRenderFrame: (() -> Bool)?

    private let driver: DiagnosticsEnvironment.FrameDriver
    private weak var window: NSWindow?
    private var lastInput: CFTimeInterval?
    private var lastPresent: CFTimeInterval?
    static let echoWindow: CFTimeInterval = 0.05

    private let metalLayer: CAMetalLayer
    private var link: CAMetalDisplayLink?
    private var pacingLink: CADisplayLink?
    private var owesDraw = false
    /// CADisplayLink retains its target; keep ownership back to the scheduler
    /// weak so closing a pane releases its pacing link and layer.
    private final class PacingTarget: NSObject {
        weak var scheduler: FrameScheduler?
        init(_ scheduler: FrameScheduler) { self.scheduler = scheduler }
        @objc func tick(_ link: CADisplayLink) { scheduler?.pacingTick(link) }
    }
    private var resumedAt: CFTimeInterval?
    private var previousPresentationTimestamp: CFTimeInterval?
    /// Survives `attach(to:)` recreating the link, or a tab moving windows
    /// would lose `RenderPolicy`'s rate.
    private var desiredFrameRateRange = CAFrameRateRange.default

    init(metalLayer: CAMetalLayer,
        driver: DiagnosticsEnvironment.FrameDriver = DiagnosticsEnvironment.frameDriver()) {
        self.driver = driver
        self.metalLayer = metalLayer
        super.init()
    }

    isolated deinit {
        link?.invalidate()
        pacingLink?.invalidate()
    }

    /// Recreates the link for `window`; nil tears it down.
    func attach(to window: NSWindow?) {
        self.window = window
        owesDraw = false
        lastInput = nil
        lastPresent = nil
        metalLayer.displaySyncEnabled = driver != .ondemandNoSync
        link?.invalidate()
        pacingLink?.invalidate()
        link = nil
        pacingLink = nil
        resumedAt = nil
        previousPresentationTimestamp = nil
        guard window != nil else {
            link = nil
            return
        }
        if driver != .displaylink {
            guard let view = window?.contentView else { return }
            let pacing = view.displayLink(target: PacingTarget(self), selector: #selector(PacingTarget.tick(_:)))
            pacing.add(to: .main, forMode: .common)
            pacing.isPaused = true
            pacing.preferredFrameRateRange = desiredFrameRateRange
            pacingLink = pacing
            return
        }
        let newLink = CAMetalDisplayLink(metalLayer: metalLayer)
        newLink.delegate = self
        newLink.add(to: .main, forMode: .common)
        newLink.isPaused = true
        newLink.preferredFrameRateRange = desiredFrameRateRange
        // A measurement hook like `CORTA_MAX_DRAWABLES`, not a config key.
        // `RenderPolicy` manages only the rate range, so nothing overrides it.
        // Unset, the link keeps its default of 2 frames: setting 1 measured no
        // shorter (`PERFORMANCE.md` §5.7).
        if let latency = DiagnosticsEnvironment.frameLatency() {
            newLink.preferredFrameLatency = latency
        }
        link = newLink
    }

    /// Wakes the scheduler for the next vsync. Idempotent, main thread.
    func resume() {
        if RenderMetrics.isEnabled, isPaused {
            resumedAt = CACurrentMediaTime()
            previousPresentationTimestamp = nil
        }
        link?.isPaused = false
        pacingLink?.isPaused = false
    }

    func noteInput(now: CFTimeInterval? = nil) {
        guard driver != .displaylink else { return }
        lastInput = now ?? CACurrentMediaTime()
    }

    /// Pure echo/rate gate: output outside this window and all continuous
    /// streams stay paced by the link. Immediate echoes require a paused link.
    static func mayPresentEcho(now: CFTimeInterval, lastInput: CFTimeInterval?,
        lastPresent: CFTimeInterval?, maximumFPS: Int, isPaused: Bool) -> Bool {
        guard isPaused, let lastInput, now >= lastInput,
            now - lastInput <= echoWindow else { return false }
        return lastPresent.map { now - $0 >= 1 / Double(max(1, maximumFPS)) } ?? true
    }

    private var echoMaximumFPS: Int {
        let panel = window?.screen?.maximumFramesPerSecond ?? 60
        let ceiling = desiredFrameRateRange.maximum
        return ceiling > 0 ? min(panel, max(1, Int(ceiling))) : panel
    }

    /// Consumes an echo wake only in the opt-in experiment. Prepare before
    /// acquire: synchronized output and unchanged pixels acquire no drawable.
    @discardableResult
    func renderEchoOnDemand(now: CFTimeInterval? = nil) -> Bool {
        guard driver != .displaylink, pacingLink != nil else { return false }
        let now = now ?? CACurrentMediaTime()
        guard Self.mayPresentEcho(now: now, lastInput: lastInput, lastPresent: lastPresent,
                maximumFPS: echoMaximumFPS, isPaused: isPaused)
        else { return false }
        return RenderMetrics.measure(.cpuFrame) {
            guard shouldRenderFrame?() == true else { return true }
            previousPresentationTimestamp = nil
            resumedAt = nil
            guard let drawable = RenderMetrics.measure(.drawableWait, { metalLayer.nextDrawable() }) else {
                owesDraw = true
                resume()
                return true
            }
            let drawn: Bool
            if let onRenderFrame { drawn = onRenderFrame(metalLayer.drawableSize, drawable) }
            else { drawable.present(); drawn = true }
            lastPresent = CACurrentMediaTime()
            owesDraw = !drawn
            if !drawn { resume() }
            return true
        }
    }

    /// Whether a display link is on the run loop for this layer.
    var isAttached: Bool { link != nil || pacingLink != nil }

    var isPaused: Bool {
        get { link?.isPaused ?? pacingLink?.isPaused ?? true }
        set {
            if newValue {
                resumedAt = nil
                previousPresentationTimestamp = nil
                link?.isPaused = true
                pacingLink?.isPaused = true
            } else { resume() }
        }
    }

    /// The rate ceiling, adapted by `RenderPolicy` (focus, Low Power Mode,
    /// thermal, scrolling). It spaces wakeups; `isPaused` decides whether any
    /// happen.
    var preferredFrameRateRange: CAFrameRateRange {
        get { desiredFrameRateRange }
        set {
            desiredFrameRateRange = newValue
            link?.preferredFrameRateRange = newValue
            pacingLink?.preferredFrameRateRange = newValue
        }
    }

    /// The experiment uses a separate pacing link. Mixing nextDrawable with
    /// a paused CAMetalDisplayLink trapped on this OS, so never create both.
    @objc private func pacingTick(_ pacing: CADisplayLink) {
        RenderMetrics.measure(.cpuFrame) {
            let now = CACurrentMediaTime()
            if RenderMetrics.isEnabled {
                RenderMetrics.noteConditions(minimum: desiredFrameRateRange.minimum,
                    maximum: desiredFrameRateRange.maximum, preferred: desiredFrameRateRange.preferred,
                    lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
                let lead = (pacing.targetTimestamp - now) * 1000
                RenderMetrics.record(.callbackLead, milliseconds: lead)
                if let resumedAt {
                    RenderMetrics.record(.firstAfterResume, milliseconds: lead)
                    RenderMetrics.record(.resumeToCallback, milliseconds: (now - resumedAt) * 1000)
                    self.resumedAt = nil
                }
                if let previousPresentationTimestamp {
                    RenderMetrics.record(.frameInterval, milliseconds:
                        (pacing.targetTimestamp - previousPresentationTimestamp) * 1000)
                }
                previousPresentationTimestamp = pacing.targetTimestamp
            }
            let pending = shouldRenderFrame?() == true
            guard pending || owesDraw else { isPaused = true; return }
            guard let drawable = RenderMetrics.measure(.drawableWait, { metalLayer.nextDrawable() })
            else { owesDraw = true; return }
            if RenderMetrics.isEnabled {
                RenderMetrics.notePresentationTarget(of: drawable, at: pacing.targetTimestamp)
            }
            let drawn: Bool
            if let onRenderFrame { drawn = onRenderFrame(metalLayer.drawableSize, drawable) }
            else { drawable.present(); drawn = true }
            lastPresent = CACurrentMediaTime()
            owesDraw = !drawn
            if !drawn { resume() }
        }
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
        // With no acquire to time, lateness past the target timestamp is the
        // stall signal (`PERFORMANCE.md` §5.3/§5.4).
        if RenderMetrics.isEnabled {
            RenderMetrics.notePresentationTarget(of: update.drawable, at: update.targetPresentationTimestamp)
            RenderMetrics.noteConditions(minimum: desiredFrameRateRange.minimum,
                maximum: desiredFrameRateRange.maximum, preferred: desiredFrameRateRange.preferred,
                lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
            let now = CACurrentMediaTime()
            let leadMS = (update.targetPresentationTimestamp - now) * 1000
            RenderMetrics.record(.callbackLead, milliseconds: leadMS)
            if let resumedAt {
                RenderMetrics.record(.firstAfterResume, milliseconds: leadMS)
                RenderMetrics.record(.resumeToCallback, milliseconds: (now - resumedAt) * 1000)
                self.resumedAt = nil
            }
            if let previousPresentationTimestamp {
                RenderMetrics.record(.frameInterval, milliseconds:
                    (update.targetPresentationTimestamp - previousPresentationTimestamp) * 1000)
            }
            previousPresentationTimestamp = update.targetPresentationTimestamp
            let latenessMS = (CACurrentMediaTime() - update.targetTimestamp) * 1000
            RenderMetrics.record(.drawableWait, milliseconds: max(0, latenessMS))
        }
        let stillPending = shouldRenderFrame?() ?? true
        let drawn: Bool
        if let onRenderFrame { drawn = onRenderFrame(metalLayer.drawableSize, update.drawable) }
        else { update.drawable.present(); drawn = true }
        if Self.mayPause(stillPending: stillPending, drawn: drawn) {
            link.isPaused = true
            previousPresentationTimestamp = nil
        }
    }

    /// Whether the link may pause after a tick. Not while anything is
    /// pending, and not after a dropped frame, whose drawable shows stale
    /// contents until one draws — the damage it carried was already taken,
    /// so nothing else would ask again.
    static func mayPause(stillPending: Bool, drawn: Bool) -> Bool {
        !stillPending && drawn
    }
}
