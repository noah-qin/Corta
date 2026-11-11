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

import CortaPOSIX
import Darwin
import Synchronization

/// Both pipe ends use the same lease rules as the PTY: an in-flight poll
/// keeps its read number owned until the close byte wakes it. One byte,
/// never periodic polling; CLOEXEC keeps these parent-only handles private.
final class PTYCloseWakeup: Sendable {
    let readEnd: GuardedDescriptor
    private let writeEnd: GuardedDescriptor
    private let isSignalled = Mutex(false)
    /// Readiness polls taken on the two ends. An idle wait is one indefinite
    /// `poll`; a timer that wakes it would show up here, which is how the
    /// reader's old 250 ms poll was found and removed.
    private let pollsTaken = Atomic<Int>(0)

    var pollCount: Int { pollsTaken.load(ordering: .relaxed) }

    func recordPoll() { pollsTaken.wrappingAdd(1, ordering: .relaxed) }

    init() throws(PTYError) {
        var numbers = (Int32(-1), Int32(-1))
        let result = withUnsafeMutablePointer(to: &numbers) {
            $0.withMemoryRebound(to: Int32.self, capacity: 2) { pipe($0) }
        }
        guard result == 0 else { throw .ioFailed(code: errno) }
        guard fcntl(numbers.0, F_SETFD, FD_CLOEXEC) >= 0,
            fcntl(numbers.1, F_SETFD, FD_CLOEXEC) >= 0,
            fcntl(numbers.1, F_SETFL, O_NONBLOCK) >= 0 else {
            let code = errno
            Darwin.close(numbers.0)
            Darwin.close(numbers.1)
            throw .ioFailed(code: code)
        }
        readEnd = GuardedDescriptor(numbers.0)
        writeEnd = GuardedDescriptor(numbers.1)
    }

    func signalAndClose() {
        let first = isSignalled.withLock { signalled in
            guard !signalled else { return false }
            signalled = true
            return true
        }
        guard first else { return }
        _ = writeEnd.withNumber { fd in
            var byte: UInt8 = 1
            while Darwin.write(fd, &byte, 1) < 0, errno == EINTR {}
        }
        readEnd.close()
        writeEnd.close()
    }
}
