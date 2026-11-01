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
import Foundation
import Testing
@testable import Corta

struct SpaceSSHTests {
    @Test func onlyOptedInSpacePresetsUseFixedTTYCommand() {
        let target = SSHTarget(host: "alias", user: "deploy", port: 2222, identityFile: "/tmp/key with spaces")
        let tmux = RemoteTmux(id: UUID())
        let preset = SSHDestination.preset(for: target, retaining: tmux)
        #expect(preset.arguments == target.sshOptions + ["-t", "--", "alias", tmux.command])
        #expect(preset.connectTarget == target)
        #expect(SSHDestination.preset(for: target).arguments == target.sshArguments)
        #expect(!SSHDestination.preset(for: target).retainSSH)
        #expect(SSHDestination.preset(for: target).remoteTmux == nil)
        #expect(!preset.serializedLines.joined().contains("tmuxPreviouslyEstablished"))
    }

    @Test func reconnectRebuildsTheCommandFromTheTargetAndANewToken() throws {
        let target = SSHTarget(host: "alias", user: "deploy", port: 2222, identityFile: "/tmp/key")
        let tmux = RemoteTmux(id: UUID())
        var preset = SSHDestination.preset(for: target, retaining: tmux)
        preset.retainedSSHPreamble = ["-F", "/tmp/ssh.conf"]
        preset.retainedCommandLeadIn = "PATH=/fixture/bin "
        preset.arguments = SSHDestination.retainedArguments(
            for: target, tmux: tmux, preamble: preset.retainedSSHPreamble,
            commandLeadIn: preset.retainedCommandLeadIn)
        preset.arguments[preset.arguments.count - 1] = "echo hijacked"
        preset.refreshRetainedTmuxToken(reportEstablished: true)
        let fresh = try #require(preset.remoteTmux)
        #expect(fresh.id == tmux.id)
        #expect(fresh.token != tmux.token)
        #expect(preset.tmuxPreviouslyEstablished)
        let rebuilt = SSHDestination.retainedArguments(
            for: target, tmux: fresh, preamble: ["-F", "/tmp/ssh.conf"], commandLeadIn: "PATH=/fixture/bin ")
        #expect(preset.arguments == rebuilt)
        #expect(!preset.arguments.contains { $0.contains("hijacked") || $0.contains(tmux.token.uuidString) })
        #expect(preset.arguments.contains { $0.contains(fresh.token.uuidString) })
        #expect(!preset.serializedLines.joined().contains("ssh.conf"))
        #expect(!preset.serializedLines.joined().contains("PATH="))

        var untouched = SSHDestination.preset(for: target, retaining: tmux)
        untouched.connectTarget = nil
        untouched.arguments = ["echo hijacked"]
        untouched.refreshRetainedTmuxToken(reportEstablished: true)
        #expect(untouched.arguments == ["echo hijacked"])
        #expect(untouched.remoteTmux?.token == tmux.token)
    }

    @Test @MainActor func statusDoesNotClaimMissingOrFailedConnectionsWereRestored() {
        let token = UUID()
        func report(_ signal: String) -> RemoteTmux.Report? {
            var terminal = Terminal()
            terminal.expectRemoteTmux(token: token)
            terminal.feed(Array("\u{1B}]6973;\(token.uuidString);\(signal)\u{7}".utf8))
            return terminal.remoteTmuxReport
        }
        func kind(_ signal: String?, _ previously: Bool) -> SpaceSSHStatus.Kind {
            SpaceSSHStatus(report: signal.flatMap(report), previouslyEstablished: previously).kind
        }
        #expect(kind("start;new", false) == .ready)
        #expect(kind("start;new", true) == .replaced, "a lost session is not called restored")
        #expect(kind("start;attached", true) == .attached)
        #expect(kind("start;missing", true) == .missing)
        #expect(kind(nil, true) == .attaching)
        #expect(kind(nil, false) == .starting)
        let failed = SpaceSSHStatus(report: report("start;new\u{7}\u{1B}]6973;\(token.uuidString);fail;7;626164"),
                                    previouslyEstablished: true)
        #expect(failed.kind == .failed)
        #expect(failed.detail.contains("bad"))
        // The lead answers whether programs survive a disconnect.
        let kept = L10n.text("space.ssh.lead.kept"), notKept = L10n.text("space.ssh.lead.notKept")
        #expect(SpaceSSHStatus(report: nil, previouslyEstablished: false).lead == kept)
        #expect(SpaceSSHStatus(report: report("start;attached"), previouslyEstablished: true).lead == kept)
        #expect(SpaceSSHStatus(report: report("start;missing"), previouslyEstablished: false).lead == notKept)
        #expect(failed.lead == notKept)
        #expect(SpaceSSHStatus(report: report("start;new"), previouslyEstablished: true).lead
            == L10n.text("space.ssh.lead.lost"))
        #expect(failed.tint == .systemRed)
        #expect(SpaceSSHStatus(report: nil, previouslyEstablished: false).tint == .secondaryLabelColor)
        #expect(SpaceSSHStatus(report: report("start;new"), previouslyEstablished: false).title
            == kept + " · " + L10n.text("space.ssh.ready"))
    }

    @Test @MainActor func openingDialogResetsThePerConnectionChoice() {
        let draft = RemoteConnectDraft()
        #expect(!draft.retainSSH, "keeping programs running is off by default")
        draft.retainSSH = true
        draft.reset(mode: .ssh)
        #expect(!draft.retainSSH, "and every new dialog starts off again")
        draft.reset(mode: .sftp)
        #expect(draft.mode == .sftp)
    }
}
