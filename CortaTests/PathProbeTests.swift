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

@testable import Corta

/// A `stat` on a mount whose server has gone can block for minutes. These
/// stand one in with a check that never returns (until the test releases it)
/// and pin that the caller is held for the timeout at most.
struct PathProbeTests {
    /// Blocks `check` calls on `hung` paths until released.
    private final class Gate: Sendable {
        let released = Mutex(false)
        func wait() {
            let deadline = ContinuousClock.now + .seconds(10)
            while !released.withLock({ $0 }), ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    @Test("a directory that never answers counts as absent once the timeout passes")
    func hungDirectoryIsAbsentAfterTheTimeout() {
        let gate = Gate()
        defer { gate.released.withLock { $0 = true } }
        let started = ContinuousClock.now
        let found = PathProbe.directories(
            among: ["/fine", "/hung", "/fine"], timeout: .milliseconds(200)
        ) { path in
            if path == "/hung" { gate.wait() }
            return true
        }
        #expect(found == ["/fine"])
        #expect(started.duration(to: .now) < .seconds(5))
    }

    @Test("real directories are found and files are not")
    func realPaths() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-path-probe-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let found = PathProbe.directories(
            among: ["/tmp", file.path, "/no/such/place"], timeout: .seconds(5))
        #expect(found == ["/tmp"])
    }

    @MainActor
    @Test("a reference check answers off the main thread and is then cached")
    func referenceProbeAnswersAndCaches() async {
        let calls = Mutex(0)
        let probe = FileReferenceProbe(check: { _ in
            calls.withLock { $0 += 1 }
            return true
        })
        #expect(probe.cached("/a.swift") == nil)
        var answers: [Bool] = []
        probe.probe("/a.swift") { answers.append($0) }
        probe.probe("/a.swift") { answers.append($0) }
        await waitUntil("answered") { answers.count == 2 }
        #expect(answers == [true, true])
        #expect(probe.cached("/a.swift") == true)
        #expect(calls.withLock { $0 } == 1, "one check for both callers")
    }

    @MainActor
    @Test("checks that never return hold a bounded number of slots, never the caller")
    func hungReferenceChecksAreBounded() {
        let gate = Gate()
        defer { gate.released.withLock { $0 = true } }
        let started = Mutex(0)
        let probe = FileReferenceProbe(check: { _ in
            started.withLock { $0 += 1 }
            gate.wait()
            return false
        })
        for index in 0..<(FileReferenceProbe.maximumInFlight + 5) {
            probe.probe("/hung/\(index)") { _ in }
        }
        Thread.sleep(forTimeInterval: 0.2)
        #expect(started.withLock { $0 } <= FileReferenceProbe.maximumInFlight)
    }

    @Test("progress reports are let through at most once per interval")
    func progressPacerSpacesReports() {
        let pacer = SFTPTransferQueue.ProgressPacer(interval: .milliseconds(50))
        let start = ContinuousClock.now
        #expect(pacer.admits(now: start))
        #expect(!pacer.admits(now: start + .milliseconds(10)))
        #expect(!pacer.admits(now: start + .milliseconds(49)))
        #expect(pacer.admits(now: start + .milliseconds(50)))
    }
}
