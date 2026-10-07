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

@Suite(.serialized)
struct TerminalSessionIOFailureTests {
    private func wait(_ condition: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + testTimeout(5)
        while !condition(), ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }

    @Test func aReaderFailureIsReportedWithALiveChildAndReplayed() throws {
        var seams = TerminalSession.Seams()
        seams.readerSource = ReaderSource(read: { _ in throw PTYError.ioFailed(code: EINVAL) }, isReadable: { false })
        let session = try TerminalSession(executable: "/bin/cat", seams: seams)
        defer { session.stop() }
        let failures = Mutex<[TerminalSession.IOFailure]>([])
        session.onIOFailure = { failure in
            // The callback can read the session: it is outside the state lock.
            _ = session.snapshot()
            failures.withLock { $0.append(failure) }
        }
        session.start()
        #expect(wait { !failures.withLock { $0.isEmpty } })
        #expect(session.pty.exitStatus == nil)
        #expect(session.ioFailure?.operation == .read)
        #expect(session.write([65]) == .failed)
        let replay = Mutex<[TerminalSession.IOFailure]>([])
        session.onIOFailure = { failure in replay.withLock { $0.append(failure) } }
        #expect(replay.withLock { $0 } == failures.withLock { $0 })
        #expect(failures.withLock { $0.count } == 1)
    }

    @Test func aWriterFailureDiscardsLaterChunksAndRejectsFurtherInput() throws {
        var seams = TerminalSession.Seams()
        let attempts = Mutex(0)
        seams.writerSink = { _ in
            attempts.withLock { $0 += 1 }
            throw PTYError.ioFailed(code: EBADF)
        }
        let session = try TerminalSession(executable: "/bin/cat", seams: seams)
        defer { session.stop() }
        let failures = Mutex<[TerminalSession.IOFailure]>([])
        session.onIOFailure = { failure in failures.withLock { $0.append(failure) } }
        #expect(session.write(chunks: [[1], [2], [3]]) == .accepted)
        #expect(wait { !failures.withLock { $0.isEmpty } })
        #expect(attempts.withLock { $0 } == 1)
        #expect(session.ioFailure?.operation == .write)
        #expect(session.write([4]) == .failed)
        #expect(failures.withLock { $0.count } == 1)
    }

    /// `EIO` on a write is Darwin saying the last replica holder closed it —
    /// a child that exited (or left its terminal) with input still queued,
    /// not a fault. It must not raise the runtime-failure view, nor stop the
    /// reader from reporting the exit.
    @Test func aWriteAfterTheReplicaClosedIsAHangupNotAFailure() throws {
        var seams = TerminalSession.Seams()
        let attempts = Mutex(0)
        seams.writerSink = { _ in
            attempts.withLock { $0 += 1 }
            throw PTYError.ioFailed(code: EIO)
        }
        let session = try TerminalSession(executable: "/bin/cat", seams: seams)
        defer { session.stop() }
        let failures = Mutex(0)
        session.onIOFailure = { _ in failures.withLock { $0 += 1 } }
        #expect(session.write(chunks: [[1], [2], [3]]) == .accepted)
        #expect(wait { session.write([4]) == .stopped })
        #expect(attempts.withLock { $0 } == 1, "queued input after the hangup is dropped")
        #expect(session.ioFailure == nil)
        Thread.sleep(forTimeInterval: 0.1)
        #expect(failures.withLock { $0 } == 0)
    }

    @Test func ownerShutdownDoesNotReportAnIOFailure() throws {
        let session = try TerminalSession(executable: "/bin/cat")
        let failures = Mutex(0)
        session.onIOFailure = { _ in failures.withLock { $0 += 1 } }
        session.start()
        session.stop()
        #expect(session.write([65]) == .stopped)
        Thread.sleep(forTimeInterval: 0.3)
        #expect(failures.withLock { $0 } == 0)
    }
}
