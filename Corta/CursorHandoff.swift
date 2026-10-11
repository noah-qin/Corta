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

/// Main owns layer effects; the reader can invalidate a pending handoff before
/// any main-actor callback runs. Render snapshots carry the same token/revision.
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
            $0.handoff.takeBack()
        }
    }
    func handOff(expectedOutputRevision: UInt64) -> UInt64? {
        state.withLock {
            guard $0.outputRevision == expectedOutputRevision, $0.handoff.phase == .metal else {
                return nil
            }
            return $0.handoff.handOff()
        }
    }
    func takeBack() { state.withLock { $0.handoff.takeBack() } }
    func presented(_ token: UInt64) -> Bool { state.withLock { $0.handoff.presented(token) } }
    func stop() { state.withLock { $0.handoff.stop() } }
}
