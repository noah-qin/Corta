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
    }
    private struct State {
        var handoff = CursorHandoff()
        var sessionGeneration = 0
        var outputRevision: UInt64 = 0
        var presentation: CursorLayerPresentation?

        mutating func takeBack() {
            presentation?.retire()
            // Main keeps the layer until the replacement frame is presented.
            // Drop only this mailbox's reference so subsequent output batches
            // do not reacquire the retired presentation's mutex.
            presentation = nil
            handoff.takeBack()
        }
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
    func noteOutput(generation: Int) {
        state.withLock {
            guard generation == $0.sessionGeneration else { return }
            $0.outputRevision &+= 1
            $0.takeBack()
        }
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
        state.withLock {
            $0.takeBack()
        }
    }
    func presented(_ token: UInt64) -> Bool {
        state.withLock {
            let accepted = $0.handoff.presented(token)
            if accepted && $0.handoff.phase == .metal { $0.presentation = nil }
            return accepted
        }
    }
    func stop() {
        state.withLock {
            $0.presentation?.retire()
            $0.handoff.stop()
            $0.presentation = nil
        }
    }
}
