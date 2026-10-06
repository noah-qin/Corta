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
@testable import CortaTerminal

/// The window title's own state, without a pane: when the size shows, and
/// the proxy icon's directory probe, which must never block the main actor
/// on a mount that does not answer.
///
/// Serialized: the directory-probe tests share the process-wide admission of
/// two, and one of them deliberately fills it.
@MainActor
@Suite(.serialized)
struct PaneWindowTitleTests {
    @Test("without a session the title is the app's name")
    func noSessionIsCorta() {
        #expect(PaneWindowTitle().composed == "Corta")
    }

    @Test("the grid size shows only while a resize is being noted")
    func transientSizeComesAndGoes() throws {
        let session = try TerminalSession(
            executable: "/bin/cat", arguments: [], environment: ChildEnvironment.default(),
            size: TerminalSize(rows: 24, columns: 80), workingDirectory: "/")
        defer { session.stop() }
        let title = PaneWindowTitle()
        defer { title.stop() }
        title.reset(session: session)
        title.gridSize = { TerminalSize(rows: 24, columns: 80) }
        #expect(!title.composed.contains("80×24"))
        title.noteTransientSizeChange()
        #expect(title.composed.contains("80×24"))
        title.endTransientSize()
        #expect(!title.composed.contains("80×24"))
    }

    /// Two probes stuck on a slow mount fill the admission; a third pane's
    /// probe is retried once there is room rather than dropped, so the pane
    /// gets its proxy icon without waiting for its next `cd`.
    @Test("a probe refused while two are stuck is retried, not dropped")
    func refusedProbeIsRetried() async {
        let release = DispatchSemaphore(value: 0)
        let entered = Mutex(0)
        let stuck = (0..<2).map { _ in
            PaneWindowTitle(isDirectory: { _ in
                entered.withLock { $0 += 1 }
                release.wait()
                return true
            })
        }
        for title in stuck { title.probeRepresentedDirectory("/slow-mount") }
        var deadline = ContinuousClock.now + .seconds(3) * testTimeoutScale
        while entered.withLock({ $0 }) < 2, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(entered.withLock { $0 } == 2)

        let asked = Mutex(false)
        let third = PaneWindowTitle(isDirectory: { _ in
            asked.withLock { $0 = true }
            return true
        })
        third.probeRepresentedDirectory("/fine")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!asked.withLock { $0 }, "no room yet: two probes hold the admission")

        release.signal()
        release.signal()
        deadline = ContinuousClock.now
            + .seconds(PaneWindowTitle.directoryProbeRetryDelay + 3) * testTimeoutScale
        while !asked.withLock({ $0 }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(asked.withLock { $0 }, "the refused probe ran once there was room")
        for title in stuck + [third] { title.stop() }
    }

    @Test("a blocked directory probe does not block the main actor")
    func slowDirectoryProbeIsBackgroundWork() async {
        let entered = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        let title = PaneWindowTitle(isDirectory: { _ in
            entered.withLock { $0 = true }
            release.wait()
            return true
        })
        defer { release.signal() }
        title.probeRepresentedDirectory("/slow-mount")
        let deadline = ContinuousClock.now + .seconds(3)
        while !entered.withLock({ $0 }), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(entered.withLock { $0 })
        title.probeRepresentedDirectory(nil)
        title.stop()
    }
}
