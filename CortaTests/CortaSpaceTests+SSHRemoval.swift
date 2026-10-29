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

extension CortaSpaceTests {
    @Test func retainedRemovalWithoutAWindowStillAsksAndCompletes() throws {
        let (controller, host) = try makeWindow()
        defer { close(controller, host) }
        host.toolbarWindow = nil
        var presented: NSAlert?
        host.space.presentAlert = { alert, _, done in
            presented = alert
            done(.alertSecondButtonReturn)
        }
        var record = SpaceSessionRecord(number: 1, ssh: SSHTarget(host: "fixture"))
        record.retainSSH = true
        let replaced = UUID()
        record.supersededTmuxNames = [RemoteTmux(id: replaced).sessionName]
        let session = SpaceSession(record: record)
        var completed = false
        host.space.confirmRetainedRemoval([session]) { completed = true }
        let alert = try #require(presented)
        #expect(alert.buttons.allSatisfy { $0.bezelStyle == .glass })
        let text = alert.informativeText
        #expect(text.contains(RemoteTmux(id: session.id).sessionName))
        #expect(text.contains(RemoteTmux(id: replaced).sessionName))
        #expect(text.contains("tmux kill-session -t '="))
        #expect(completed)

        completed = false
        presented = nil
        host.space.presentAlert = { alert, _, done in
            presented = alert
            done(.alertFirstButtonReturn)
        }
        host.space.confirmRetainedRemoval([session]) { completed = true }
        #expect(presented != nil)
        #expect(!completed, "cancel does not remove the session")

        presented = nil
        completed = false
        host.space.confirmRetainedRemoval([SpaceSession(record: SpaceSessionRecord(number: 2))]) { completed = true }
        #expect(presented == nil)
        #expect(completed)

        presented = nil
        host.space.presentAlert = { alert, _, done in
            presented = alert
            done(.alertFirstButtonReturn)
        }
        host.space.endRemoteSession(session)
        let endAlert = try #require(presented)
        #expect(endAlert.buttons.allSatisfy { $0.bezelStyle == .glass })
        #expect(endAlert.informativeText.contains(RemoteTmux(id: session.id).sessionName))
    }
}
