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
import Dispatch
import Foundation
import Synchronization
import Testing

@testable import CortaSFTP

@Suite("SFTP channel cleanup", .serialized)
struct SFTPChannelLifecycleTests {
    @Test(arguments: [false, true])
    func releasingAChannelCancelsItsStderrDrain(_ explicitClose: Bool) async throws {
        var channel: SFTPSubprocessChannel? = try .spawn(
            host: "unused", executable: "/bin/cat", arguments: [], environment: [:])
        let source = try #require(channel?.stderrSource)
        weak var released = channel
        if explicitClose { channel?.close() }
        channel = nil
        let deadline = SuspendingClock.now + .seconds(5)
        while !source.isCancelled || released != nil, SuspendingClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(released == nil)
        #expect(source.isCancelled)
    }

    /// `close` runs on the main actor. A reap in progress used to be waited
    /// out right there, one millisecond at a time, for as long as it took.
    @Test func closeDoesNotWaitOutAReapInProgress() async throws {
        let channel = try SFTPSubprocessChannel.spawn(
            host: "unused", executable: "/bin/sleep", arguments: ["60"], environment: [:])
        defer { channel.close() }
        let holding = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        let hold = Duration.seconds(1)
        let holder = Thread {
            channel.holdingReapForTesting {
                holding.withLock { $0 = true }
                _ = release.wait(timeout: .now() + 1)
            }
        }
        holder.start()
        while !holding.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(1)) }
        let elapsed = SuspendingClock().measure { channel.close() }
        release.signal()
        #expect(elapsed < hold / 2, "close took \(elapsed) behind a held reap")
        // The kill still happens, once the reap has let go, and the child is reaped.
        let exit = await channel.awaitExit(timeout: .seconds(testTimeoutInterval(5)))
        #expect(exit == .signalled(signal: SIGKILL))
    }
}
