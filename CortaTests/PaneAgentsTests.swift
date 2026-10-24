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

import AppKit
import CortaTerminal
import Testing
@testable import Corta

@MainActor
@Suite(.serialized)
struct PaneAgentsTests {
    // Supply only a view and PTY. Loading the production pane would start a
    // renderer, shell and window services unrelated to state resolution.
    private final class Pane: ViewController {
        override func viewDidLoad() {}
    }
    private func pane() throws -> ViewController {
        let pane = Pane()
        pane.view = NSView()
        pane.session = try TerminalSession(executable: "/bin/cat", arguments: [],
            environment: ChildEnvironment.default(), workingDirectory: "/")
        pane.session.start()
        return pane
    }
    private func waitUntilTrue(timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = SuspendingClock.now + timeout
        while SuspendingClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
    private func send(_ payload: String, to pane: ViewController) async throws {
        let marker = UUID().uuidString
        // OSC 2 seals this test batch without draining any notification.
        pane.session.write(Array((payload + "\u{1B}]2;" + marker + "\u{1B}\\\n").utf8))
        #expect(await waitUntilTrue(timeout: .seconds(5)) { pane.session.windowTitle == marker })
        pane.agents.readOutput()
    }
    private func osc(_ payload: String) -> String { "\u{1B}]" + payload + "\u{1B}\\" }

    @Test func notificationsAndBellCannotRewriteReportedTaskState() async throws {
        let original = ConfigurationStore.shared.configuration
        ConfigurationStore.shared.update { $0.agentStatus = true }
        let pane = try pane()
        defer {
            pane.agents.reset(); pane.session.stop()
            ConfigurationStore.shared.update { $0 = original }
        }
        try await send(osc("7501;state=idle"), to: pane)
        #expect(pane.agents.status?.state == .idle)
        try await send(osc("7501;state=done") + osc("9;Response complete"), to: pane)
        #expect(pane.agents.status?.state == .done)
        pane.agents.bell()
        #expect(pane.agents.status?.state == .done)
        try await send(osc("7501;state=error") + osc("777;notify;Attention;Read this"), to: pane)
        #expect(pane.agents.status?.state == .error)
        pane.agents.bell()
        #expect(pane.agents.status?.state == .error)
        try await send(osc("7501;state=blocked:kind=auth") + osc("9;Other message"), to: pane)
        #expect(pane.agents.status?.state == .blocked)
        #expect(pane.agents.status?.kind == .auth)
    }

    @Test func processAndOutputCannotProveWorkingOrCompletion() async throws {
        let original = ConfigurationStore.shared.configuration
        ConfigurationStore.shared.update { $0.agentStatus = true; $0.agentProcesses = "cat" }
        let pane = try pane()
        defer {
            pane.agents.reset(); pane.session.stop()
            ConfigurationStore.shared.update { $0 = original }
        }
        #expect(await waitUntilTrue(timeout: .seconds(5)) {
            pane.agents.readOutput()
            return pane.agents.status?.state == .unknown
        })
        try await send("response finished" + osc("9;Task complete"), to: pane)
        #expect(pane.agents.status?.state == .unknown)
        pane.agents.bell()
        #expect(pane.agents.status?.state == .unknown)
        pane.agents.exited(success: true)
        #expect(pane.agents.status?.state == .idle)
        pane.agents.readOutput()
        #expect(pane.agents.status?.state == .idle, "late output cannot revive a stopped session")
    }

    @Test func sessionExitReadsCompletionThatHasNotReachedTheUIYet() async throws {
        let original = ConfigurationStore.shared.configuration
        ConfigurationStore.shared.update { $0.agentStatus = true }
        let pane = try pane()
        defer {
            pane.agents.reset(); pane.session.stop()
            ConfigurationStore.shared.update { $0 = original }
        }
        try await send(osc("7501;state=working"), to: pane)
        pane.session.write(Array((osc("7501;state=done") + "\n").utf8))
        #expect(await waitUntilTrue(timeout: .seconds(5)) { pane.session.programStatuses[""]?.state == .done })
        #expect(pane.agents.status?.state == .working)
        pane.agents.exited(success: true)
        #expect(pane.agents.status?.state == .done)
    }

    @Test func unfinishedSubtaskPreventsFalseCompletionAndClearRemovesIt() async throws {
        let original = ConfigurationStore.shared.configuration
        ConfigurationStore.shared.update { $0.agentStatus = true }
        let pane = try pane()
        defer {
            pane.agents.reset(); pane.session.stop()
            ConfigurationStore.shared.update { $0 = original }
        }
        try await send(osc("7501;state=done") + osc("7501;state=working:id=child"), to: pane)
        #expect(pane.agents.status?.state == .working)
        try await send(osc("7501;state=clear:id=child"), to: pane)
        #expect(pane.agents.status?.state == .done)
        pane.agents.exited(success: true)
        #expect(pane.agents.status?.state == .done)
        pane.agents.readOutput()
        #expect(pane.agents.status?.state == .done)
    }
}
