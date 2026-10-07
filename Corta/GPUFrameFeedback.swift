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

/// Completion tracking independent of display-link callbacks. A hung queue
/// can exhaust the drawable pool, preventing even a dropped-frame callback.
/// Only this mutex-protected value state crosses from main to GPU feedback.
/// On the suspending clock: time asleep is not GPU time. A frame submitted as
/// the lid closed was otherwise "two seconds overdue" on wake, and the pane
/// showed a renderer failure whose Try Again ends the session.
nonisolated final class GPUFrameFeedback: Sendable {
    private struct State {
        var serial: UInt64 = 0
        var pending: [UInt64: SuspendingClock.Instant] = [:]
    }
    private let state = Mutex(State())

    func begin(now: SuspendingClock.Instant = .now) -> UInt64 {
        state.withLock {
            $0.serial &+= 1
            $0.pending[$0.serial] = now
            return $0.serial
        }
    }

    func complete(_ serial: UInt64) {
        state.withLock { _ = $0.pending.removeValue(forKey: serial) }
    }

    var hasPending: Bool { state.withLock { !$0.pending.isEmpty } }

    func hasExpired(now: SuspendingClock.Instant = .now, timeout: Duration = .seconds(2)) -> Bool {
        state.withLock { current in
            guard let oldest = current.pending.values.min() else { return false }
            return oldest.duration(to: now) >= timeout
        }
    }
}
