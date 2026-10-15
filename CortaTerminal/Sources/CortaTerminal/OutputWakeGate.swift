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

import Dispatch
import Synchronization

/// Coalesces a session's per-batch output signal into at most one wake of
/// the main actor per frame.
///
/// The reader calls `noteOutput()` for every parse batch — thousands a
/// second under a flood. Only the call that finds nothing pending asks its
/// caller to wake the main actor; the frame takes the flag with
/// `takePending()`, which re-arms the wake. Between frames every further
/// batch costs two atomics. Nothing the frame drains is lost by it: the
/// bell, clipboard requests and finished commands are all read from the
/// session when the frame takes the flag.
///
/// One gate per session, so a replaced session's last flag cannot leave the
/// next one's first output without a wake.
public final class OutputWakeGate: Sendable {
    private let pending = Atomic(false)
    private let lastOutput = Atomic<UInt64>(0)

    public init() {}

    /// Reader thread, per batch.
    /// - Returns: whether the caller must wake the main actor — true only
    ///   for the first batch since the frame last took the flag.
    public func noteOutput() -> Bool {
        lastOutput.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
        return pending.compareExchange(
            expected: false, desired: true, ordering: .acquiringAndReleasing
        ).exchanged
    }

    /// The frame: whether output arrived since the last take. Clearing the
    /// flag re-arms the wake for the next batch.
    public func takePending() -> Bool {
        pending.exchange(false, ordering: .acquiringAndReleasing)
    }

    /// When the reader last noted output, on the `DispatchTime` uptime
    /// clock; zero before any. Read by what must see every batch rather
    /// than one per frame — a quiet-period timer keeps running while a
    /// paused frame loop leaves the flag set.
    public var lastOutputUptimeNanoseconds: UInt64 {
        lastOutput.load(ordering: .relaxed)
    }
}
