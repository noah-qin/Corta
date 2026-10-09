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

/// Owns one `TerminalView`'s vsync-to-drawable pipeline through
/// `CAMetalDisplayLink`, whose callback already carries a resolved
/// drawable — there is no acquire step to gate.
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

    private let metalLayer: CAMetalLayer
    private var link: CAMetalDisplayLink?
    private var resumedAt: CFTimeInterval?
    private var previousPresentationTimestamp: CFTimeInterval?
    /// Survives `attach(to:)` recreating the link, or a tab moving windows
    /// would lose `RenderPolicy`'s rate.
    private var desiredFrameRateRange = CAFrameRateRange.default

    init(metalLayer: CAMetalLayer) {
        self.metalLayer = metalLayer
        super.init()
    }

    /// Recreates the link for `window`; nil tears it down.
    func attach(to window: NSWindow?) {
        link?.invalidate()
        resumedAt = nil
        previousPresentationTimestamp = nil
        guard window != nil else {
            link = nil
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
        if RenderMetrics.isEnabled, link?.isPaused == true {
            resumedAt = CACurrentMediaTime()
            previousPresentationTimestamp = nil
        }
        link?.isPaused = false
    }

    /// Whether a display link is on the run loop for this layer.
    var isAttached: Bool { link != nil }

    var isPaused: Bool {
        get { link?.isPaused ?? true }
        set {
            if newValue {
                resumedAt = nil
                previousPresentationTimestamp = nil
                link?.isPaused = true
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
        let drawn = onRenderFrame?(metalLayer.drawableSize, update.drawable) ?? true
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
