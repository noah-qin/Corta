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

import Metal
import Synchronization
import QuartzCore

/// A standalone cursor layer, never an AppKit view's backing layer. Main owns
/// its creation, geometry, attachment and removal. Animation/opacity mutations
/// are serialized here so input/reader activity can retire it before a render
/// owner submits the replacement frame, without waiting for the main actor.
nonisolated final class CursorLayerPresentation: @unchecked Sendable {
    let layer: CALayer
    private let retired = Mutex(false)
    init(layer: CALayer) { self.layer = layer }

    func startBlink(beginTime: CFTimeInterval) -> Bool {
        retired.withLock {
            guard !$0 else { return false }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [0, 1, 0]
            blink.keyTimes = [0, 0.5, 1]
            blink.calculationMode = .discrete
            blink.duration = 1
            blink.repeatCount = .infinity
            blink.beginTime = beginTime
            layer.add(blink, forKey: "cursor.blink")
            CATransaction.commit()
            return true
        }
    }
    func retire() {
        retired.withLock {
            guard !$0 else { return }
            $0 = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAllAnimations()
            layer.opacity = 0
            CATransaction.commit()
            // The reader has no run-loop transaction to commit implicitly.
            CATransaction.flush()
        }
    }
}

/// Tokens prevent a late presented callback from reviving an obsolete cursor.
nonisolated struct CursorHandoff: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case metal, awaitingLayer, layer, awaitingMetal }
    private(set) var phase: Phase = .metal
    private(set) var token: UInt64 = 0
    mutating func handOff() -> UInt64 {
        token &+= 1
        phase = .awaitingLayer
        return token
    }
    mutating func takeBack() {
        guard phase != .metal && phase != .awaitingMetal else { return }
        token &+= 1
        phase = .awaitingMetal
    }
    mutating func presented(_ token: UInt64) -> Bool {
        guard token == self.token else { return false }
        switch phase {
        case .awaitingLayer:
            phase = .layer
            return true
        case .awaitingMetal:
            phase = .metal
            return true
        default: return false
        }
    }
    mutating func stop() {
        token &+= 1
        phase = .metal
    }
}

/// Main owns the layer graph. The reader retires its standalone presentation
/// before publishing takeback; render snapshots carry the same token/revision.
nonisolated final class CursorHandoffMailbox: Sendable {
    struct Snapshot: Sendable {
        var phase: CursorHandoff.Phase
        var token: UInt64
        var outputRevision: UInt64
        var pending: Bool { phase == .awaitingLayer || phase == .awaitingMetal }
        /// Whether a frame drawing the cursor or not (`cursorDrawn`) is the
        /// one the pending hand-off waits for: cursorless for the layer, with
        /// the cursor for Metal. Both render paths ask this, and only this.
        func awaits(cursorDrawn: Bool) -> Bool {
            pending && cursorDrawn == (phase == .awaitingMetal)
        }
    }
    private struct State {
        var handoff = CursorHandoff()
        var sessionGeneration = 0
        var outputRevision: UInt64 = 0
        var presentation: CursorLayerPresentation?
    }
    private let state = Mutex(State())
    var snapshot: Snapshot {
        state.withLock {
            Snapshot(
                phase: $0.handoff.phase, token: $0.handoff.token,
                outputRevision: $0.outputRevision)
        }
    }
    var phase: CursorHandoff.Phase { snapshot.phase }
    var token: UInt64 { snapshot.token }
    func setSessionGeneration(_ generation: Int) {
        state.withLock { $0.sessionGeneration = generation }
    }
    /// Per output batch: one lock unless a layer must be retired first.
    func noteOutput(generation: Int) {
        retireThenPublish { state in
            guard generation == state.sessionGeneration else { return false }
            state.outputRevision &+= 1
            return true
        } publish: { $0.takeBack() }
    }
    /// Arms `drawable` to settle hand-off `token` when it reaches glass. A
    /// frame dropped before glass asks again (`retry`) while that hand-off
    /// is still the pending one. Both render paths go through here; the
    /// marker gates it on the frame actually having been encoded.
    func trackPresentation(
        of drawable: any MTLDrawable, token: UInt64,
        retry: @escaping @MainActor @Sendable () -> Void,
        presented: @escaping @MainActor @Sendable (UInt64) -> Void
    ) -> FrameAcceptanceMarker {
        let accepted = FrameAcceptanceMarker()
        drawable.addPresentedHandler { [self] drawable in
            let reachedGlass = drawable.presentedTime > 0
            Task { @MainActor in
                guard accepted.isAccepted else { return }
                if reachedGlass {
                    presented(token)
                } else if case let current = snapshot, current.pending, current.token == token {
                    retry()
                }
            }
        }
        return accepted
    }

    func handOff(expectedOutputRevision: UInt64, presentation: CursorLayerPresentation? = nil) -> UInt64? {
        state.withLock {
            guard $0.outputRevision == expectedOutputRevision, $0.handoff.phase == .metal else {
                return nil
            }
            $0.presentation = presentation
            return $0.handoff.handOff()
        }
    }
    func takeBack() {
        retireThenPublish { _ in true } publish: { $0.takeBack() }
    }
    func presented(_ token: UInt64) -> Bool {
        state.withLock {
            let accepted = $0.handoff.presented(token)
            if accepted && $0.handoff.phase == .metal { $0.presentation = nil }
            return accepted
        }
    }
    func stop() {
        retireThenPublish { _ in true } publish: { $0.stop() }
    }

    /// Retires the layer, then publishes the phase change, so no frame
    /// draws a Metal cursor beside a still-blinking layer. The retire — a
    /// Core Animation flush — runs outside the lock: main's per-frame
    /// snapshot must not wait on the render server. Meanwhile the phase
    /// still says layer, so no second hand-off can start. With no layer to
    /// retire, everything happens under the one lock. Main keeps the layer
    /// itself until the replacement frame is presented; only this mailbox's
    /// reference goes, so later output batches do not reach it again.
    private func retireThenPublish(
        _ prepare: (inout State) -> Bool, publish: (inout CursorHandoff) -> Void
    ) {
        let presentation = state.withLock { state -> CursorLayerPresentation? in
            guard prepare(&state) else { return nil }
            guard let presentation = state.presentation else {
                publish(&state.handoff)
                return nil
            }
            state.presentation = nil
            return presentation
        }
        guard let presentation else { return }
        presentation.retire()
        state.withLock { publish(&$0.handoff) }
    }
}
