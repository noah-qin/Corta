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
import Foundation
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
}
