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

import Foundation
import Synchronization
import Testing

@testable import CortaTerminal

struct ReaderPriorityTests {
    @Test(arguments: [true, false])
    func focusReportsPreserveBackgroundPriority(isFocused: Bool) async throws {
        let session = try TerminalSession(
            executable: "/bin/sh", arguments: ["-c", "printf ready; exec /bin/cat"],
            size: TerminalSize(rows: 4, columns: 40))
        defer { session.stop() }
        let ready = DispatchSemaphore(value: 0)
        let echo = DispatchSemaphore(value: 0)
        let reporting = Atomic<Bool>(false)
        let observed = Mutex<TerminalSession.ReaderPriority?>(nil)
        session.onOutput = { [weak session] in
            guard let session else { return }
            if reporting.load(ordering: .acquiring) {
                observed.withLock { $0 = session.readerPriority }
                echo.signal()
            } else {
                ready.signal()
            }
        }
        session.setReaderPriority(.background)
        session.start()
        #expect(await waitForReader(ready) == .success)
        #expect(session.readerPriority == .background)
        reporting.store(true, ordering: .releasing)
        #expect(session.writeFocusReport(isFocused: isFocused) == .accepted)
        #expect(await waitForReader(echo) == .success)
        #expect(observed.withLock { $0 } == .background)
    }

    @Test func inputRaisesTheReaderBeforeItsEchoIsParsed() async throws {
        let session = try TerminalSession(
            executable: "/bin/sh",
            arguments: ["-c", "printf ready; read line; printf done"],
            size: TerminalSize(rows: 4, columns: 40))
        defer { session.stop() }
        let ready = DispatchSemaphore(value: 0)
        let echo = DispatchSemaphore(value: 0)
        let input = Atomic<Bool>(false)
        let observed = Mutex<TerminalSession.ReaderPriority?>(nil)
        session.onOutput = { [weak session] in
            guard let session else { return }
            if input.load(ordering: .acquiring) {
                observed.withLock { $0 = session.readerPriority }
                echo.signal()
            } else {
                ready.signal()
            }
        }
        session.setReaderPriority(.background)
        session.start()
        #expect(await waitForReader(ready) == .success)
        #expect(session.readerPriority == .background)
        input.store(true, ordering: .releasing)
        session.write(Array("ping\n".utf8))
        #expect(await waitForReader(echo) == .success)
        #expect(observed.withLock { $0 } == .interactive)
    }

    private func waitForReader(_ signal: DispatchSemaphore) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            let waiter = Thread {
                continuation.resume(returning:
                    signal.wait(timeout: .now() + .seconds(5 * testTimeoutScale)))
            }
            waiter.qualityOfService = .userInitiated
            waiter.start()
        }
    }
}
