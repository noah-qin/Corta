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
import Foundation
import Synchronization
import Testing
@testable import Corta

/// Who is said to be asking, what Cancel does, and how long a client can keep
/// the broker waiting or a dialog can outlive what asked it.
extension SSHAskpassBrokerTests {
    @Test func theConnectionsOwnSSHIsNotAnIntermediateStep() async throws {
        let recorder = Recorder(answer: "s3cret")
        let broker = SSHAskpassBroker(executable: Self.executable, prompter: recorder.prompter)
        defer { broker.stop() }
        let grant = try #require(broker.grant(host: "box"))
        grant.admit(getpid())
        _ = await finish(try run(grant, prompt: "box's password: "))
        #expect(recorder.asked.withLock { $0.first?.isIntermediateStep } == false)
    }

    /// The one decision about what Cancel does is the broker's, from the whole
    /// prompt: a dialog shows 2,000 characters of it, and read the rest as a
    /// password prompt whose Cancel would end the connection, while the broker
    /// did not.
    @Test func whatCancelDoesIsDecidedFromTheWholePrompt() async throws {
        let recorder = Recorder(answer: nil)
        let ended = Mutex<[pid_t]>([])
        let broker = SSHAskpassBroker(
            executable: Self.executable, prompter: recorder.prompter,
            terminate: { pid in ended.withLock { $0.append(pid) } })
        defer { broker.stop() }
        let grant = try #require(broker.grant(host: "box"))
        grant.admit(getpid())
        let prompt = String(repeating: "x", count: SSHAskpass.promptLimit + 10) + " passphrase: "
        _ = await finish(try run(grant, prompt: prompt))
        let asked = try #require(recorder.asked.withLock { $0.first })
        #expect(!asked.prompt.lowercased().contains("passphrase"), "past what a dialog shows")
        #expect(!asked.refusalEnds)
        try await Task.sleep(for: .milliseconds(200))
        #expect(ended.withLock { $0 }.isEmpty)
    }

    /// `ssh` killed — the window closed, Cancel, a deadline — says nothing to
    /// the askpass it ran: that process goes on waiting on the socket for an
    /// answer. The dialog cannot wait for it to hang up.
    @Test func theDialogGoesWhenTheConnectionsSSHDoes() async throws {
        let recorder = Recorder(answer: nil, waitsForCancel: true)
        let broker = SSHAskpassBroker(
            executable: Self.executable, prompter: recorder.prompter,
            askerCheckInterval: .milliseconds(20))
        defer { broker.stop() }
        let grant = try #require(broker.grant(host: "box"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\"$0\" \"$1\"; exit $?", Self.executable, "Password: "]
        process.environment = grant.environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // The shell stands where ssh would, with the askpass as its child.
        grant.admit(process.processIdentifier)
        let deadline = SuspendingClock.now + .seconds(10) * testTimeoutScale
        while recorder.asked.withLock({ $0.isEmpty }), SuspendingClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorder.asked.withLock { $0.count } == 1)
        kill(process.processIdentifier, SIGKILL)
        _ = await finish(process)
        while !recorder.cancelled.withLock({ $0 }), SuspendingClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorder.cancelled.withLock { $0 })
    }

    /// Silent clients each hold a thread. They are bounded, and one past the
    /// bound is told at once rather than queued behind them.
    @Test func clientsThatSayNothingAreBoundedAndDropped() async throws {
        let recorder = Recorder(answer: nil)
        let broker = SSHAskpassBroker(
            executable: Self.executable, prompter: recorder.prompter,
            requestTimeout: .seconds(60), readingClientLimit: 2)
        defer { broker.stop() }
        let grant = try #require(broker.grant(host: "box"))
        let path = try #require(grant.environment[SSHAskpass.socketVariable])
        func connected() throws -> Int32 {
            var address = try #require(SSHAskpass.socketAddress(path))
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            #expect(result == 0)
            return descriptor
        }
        let held = [try connected(), try connected()]
        defer { held.forEach { close($0) } }
        // Each accepted in turn, so the third finds the two already counted.
        try await Task.sleep(for: .milliseconds(100))
        let third = try connected()
        defer { close(third) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(third, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var byte: UInt8 = 0
        #expect(read(third, &byte, 1) == 0, "end of file, not a wait")
    }

    /// The limit is on the whole request: a byte every so often used to reset it.
    @Test func aRequestHasOneDeadlineHoweverItDribbles() throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { pair.forEach { close($0) } }
        let writer = pair[1]
        let dribble = Thread {
            var byte = UInt8(ascii: "x")
            for _ in 0..<40 {
                guard write(writer, &byte, 1) == 1 else { return }
                Thread.sleep(forTimeInterval: 0.05)
            }
            // So a reader with no deadline fails this test rather than hanging it.
            shutdown(writer, SHUT_WR)
        }
        dribble.start()
        let clock = SuspendingClock()
        var line: Data? = Data()
        let elapsed = clock.measure {
            line = SSHAskpass.readLine(from: pair[0], limit: 1024, deadline: .now + .milliseconds(300))
        }
        #expect(line == nil)
        #expect(elapsed < .seconds(1), "\(elapsed)")
    }
}
