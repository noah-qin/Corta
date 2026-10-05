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
    /// Survives `attach(to:)` recreating the link, or a tab moving windows
    /// would lose `RenderPolicy`'s rate.
    private var desiredFrameRateRange = CAFrameRateRange.default
    /// The flash guard's state; stored, since the stand-in must stay until a
    /// frame is actually presented.
    private(set) var firstPresentState: FirstPresentState = .idle

    init(metalLayer: CAMetalLayer) {
        self.metalLayer = metalLayer
        super.init()
    }

    /// Recreates the link for `window`; nil tears it down.
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
        link?.isPaused = false
    }

    /// Whether a display link is on the run loop for this layer.
    var isAttached: Bool { link != nil }

    var isPaused: Bool {
        get { link?.isPaused ?? true }
        set { link?.isPaused = newValue }
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

    /// Arms the flash guard and returns; used before a window is shown and
    /// after a theme change. Never pumps the run loop, which would nest
    /// timers and delegates inside what looks like a leaf call. The layer's
    /// `backgroundColor` stands in as the theme's clear colour until the real
    /// frame lands; with no link yet, the next `attach(to:)` completes it.
    func requestFirstPresent() {
        let bg = TerminalColorPalette.clearColor
        metalLayer.backgroundColor = CGColor(
            red: CGFloat(bg.x), green: CGFloat(bg.y), blue: CGFloat(bg.z),
            alpha: CGFloat(bg.w))
        firstPresentState = .awaitingFrame
        link?.isPaused = false
    }

    /// The first frame is committed but not yet on the glass; stripping the
    /// stand-in now showed the desktop for one compositor frame on reopen. It
    /// is retired on the next tick instead.
    func noteFrameSubmitted() {
        guard firstPresentState == .awaitingFrame else { return }
        firstPresentState = .submitted
    }

    /// Back to `.idle`, on the tick after submission (tests call it directly).
    /// A no-op when idle, so a stray call never strips a newer stand-in.
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
        // With no acquire to time, lateness past the target timestamp is the
        // stall signal (`PERFORMANCE.md` §5.3/§5.4).
        if RenderMetrics.isEnabled {
            let latenessMS = (CACurrentMediaTime() - update.targetTimestamp) * 1000
            RenderMetrics.record(.drawableWait, milliseconds: max(0, latenessMS))
        }
        let stillPending = shouldRenderFrame?() ?? true
        // Last tick's frame is on the glass; retire the stand-in.
        let retiringStandIn = firstPresentState == .submitted
        if retiringStandIn { notePresentedFrame() }
        var drawn = true
        if let onRenderFrame {
            drawn = onRenderFrame(metalLayer.drawableSize, update.drawable)
            // Only a drawn frame may retire the stand-in; a dropped one would
            // strip it over a drawable that was never drawn into.
            if drawn { noteFrameSubmitted() }
        }
        if Self.mayPause(stillPending: stillPending, drawn: drawn, firstPresentState: firstPresentState) {
            link.isPaused = true
        }
    }

    /// Whether the link may pause after a tick. Not while anything is
    /// pending; not after a dropped frame, whose drawable shows stale
    /// contents until one draws — the damage it carried was already taken,
    /// so nothing else would ask again; and not while a stand-in is up, so it
    /// retires on time.
    static func mayPause(stillPending: Bool, drawn: Bool, firstPresentState: FirstPresentState) -> Bool {
        !stillPending && drawn && firstPresentState != .submitted
    }
}

/// The flash guard (`FrameScheduler.requestFirstPresent`).
enum FirstPresentState: Equatable {
    case idle
    /// Requested; the layer's `backgroundColor` stands in.
    case awaitingFrame
    /// Scheduled; the stand-in stays until the next tick.
    case submitted
}
