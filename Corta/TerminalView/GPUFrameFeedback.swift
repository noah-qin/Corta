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

/// A copyable Sendable reference keeps the noncopyable atomic's storage shared
/// across the GPU callback and main-actor hop, including older Swift compilers.
/// Created only for cursor handoff frames, never the ordinary frame hot path.
nonisolated final class FrameAcceptanceMarker: Sendable {
    private let accepted = Atomic<Bool>(false)
    var isAccepted: Bool { accepted.load(ordering: .acquiring) }
    func finishEncoding(_ drawn: Bool) { accepted.store(drawn, ordering: .releasing) }
}

/// Completion tracking independent of display-link callbacks. A hung queue
/// can exhaust the drawable pool, preventing even a dropped-frame callback.
/// Only this mutex-protected value state crosses from main to GPU feedback.
/// On the suspending clock: time asleep is not GPU time. A frame submitted as
/// the lid closed was otherwise "two seconds overdue" on wake, and the pane
/// showed a renderer failure whose Try Again ends the session.
nonisolated final class GPUFrameFeedback: Sendable {
    /// Frames in flight are bounded by the backend's slots, far below this.
    /// A fixed ring, so a frame's begin and end allocate nothing; were it
    /// ever full, the oldest entry is kept, which is the one that expires.
    static let capacity = 8

    private struct State {
        var serial: UInt64 = 0
        var pending = ContiguousArray<(serial: UInt64, began: SuspendingClock.Instant)?>(
            repeating: nil, count: GPUFrameFeedback.capacity)
    }
    private let state = Mutex(State())

    func begin(now: SuspendingClock.Instant = .now) -> UInt64 {
        state.withLock {
            $0.serial &+= 1
            let slot = Int($0.serial % UInt64(Self.capacity))
            if $0.pending[slot] == nil { $0.pending[slot] = ($0.serial, now) }
            return $0.serial
        }
    }

    func complete(_ serial: UInt64) {
        state.withLock {
            let slot = Int(serial % UInt64(Self.capacity))
            if $0.pending[slot]?.serial == serial { $0.pending[slot] = nil }
        }
    }

    var hasPending: Bool { state.withLock { $0.pending.contains { $0 != nil } } }

    func hasExpired(now: SuspendingClock.Instant = .now, timeout: Duration = .seconds(2)) -> Bool {
        state.withLock { current in
            var oldest: SuspendingClock.Instant?
            for entry in current.pending {
                guard let entry else { continue }
                if oldest.map({ entry.began < $0 }) ?? true { oldest = entry.began }
            }
            guard let oldest else { return false }
            return oldest.duration(to: now) >= timeout
        }
    }
}
