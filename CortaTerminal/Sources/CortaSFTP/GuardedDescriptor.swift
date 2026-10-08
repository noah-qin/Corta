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

import Darwin
import Synchronization

/// A descriptor number that no other file can take while a system call on it
/// is in flight, and whose `close()` never waits for one.
///
/// Checking "not closed" and then calling `read(2)` is two steps: a `close()`
/// between them frees the number, the next `open` anywhere in the process
/// claims it, and the call lands on a stranger's file. Here every use is
/// bracketed by `enter()`/`leave()`, and a `close()` that finds a call in
/// flight leaves the number open for the last one out to close.
///
/// Deferred, not done in place: Darwin's `close(2)` (and `dup2` over the
/// number) sleeps until an in-flight call on the file returns — measured: a
/// `close` of a pty primary with a reader parked in `read` waited out the
/// child's 30-second `sleep`. Callers keep their calls bounded (a timed
/// `poll` before a read) so the deferred close follows promptly.
///
/// This file exists twice, byte for byte: in `CortaTerminal` and in
/// `CortaSFTP`, which shares no code with the core. `CortaSFTPTests` holds
/// the two equal; change both or neither.
final class GuardedDescriptor: Sendable {
    let number: Int32

    private struct State {
        var inFlight = 0
        var isClosed = false
        /// The number itself has been given back to the kernel.
        var isReleased = false
    }

    private let state = Mutex(State())

    init(_ number: Int32) {
        self.number = number
    }

    deinit {
        close()
    }

    var isClosed: Bool { state.withLock { $0.isClosed } }

    /// `false` once closed; on `true`, `leave()` must follow.
    func enter() -> Bool {
        state.withLock { state in
            guard !state.isClosed else { return false }
            state.inFlight += 1
            return true
        }
    }

    func leave() {
        let release = state.withLock { state -> Bool in
            state.inFlight -= 1
            guard state.isClosed, state.inFlight == 0, !state.isReleased else { return false }
            state.isReleased = true
            return true
        }
        if release { Darwin.close(number) }
    }

    /// `nil` once closed; otherwise `body`'s result, with the number held.
    func withNumber<Result, Failure: Error>(
        _ body: (Int32) throws(Failure) -> Result
    ) throws(Failure) -> Result? {
        guard enter() else { return nil }
        defer { leave() }
        return try body(number)
    }

    /// Idempotent and non-blocking; `true` for the call that closed it. With a
    /// call in flight the number is closed when that call leaves.
    @discardableResult
    func close() -> Bool {
        let outcome = state.withLock { state -> (first: Bool, releaseNow: Bool) in
            guard !state.isClosed else { return (false, false) }
            state.isClosed = true
            guard state.inFlight == 0 else { return (true, false) }
            state.isReleased = true
            return (true, true)
        }
        if outcome.releaseNow { Darwin.close(number) }
        return outcome.first
    }
}
