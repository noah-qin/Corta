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
import Testing
@testable import CortaTerminal

struct RemoteTmuxTests {
    @Test func startupIsTokenBoundAndOnlyFailureMayFollowIt() {
        let token = UUID()
        func signal(_ payload: String) -> [UInt8] { Array(("\u{1B}]6973;" + payload + "\u{7}").utf8) }
        let fail = signal(token.uuidString + ";fail;9;6261641b0a")
        var ignored = Terminal()
        ignored.expectRemoteTmux(token: token)
        ignored.feed(signal("wrong;start;attached"))
        #expect(ignored.remoteTmuxReport?.outcome == nil)

        var early = Terminal()
        early.expectRemoteTmux(token: token)
        let new = signal(token.uuidString + ";start;new")
        for byte in new { early.feed([byte]) }
        #expect(early.remoteTmuxReport?.outcome == .new)
        early.feed(signal(token.uuidString + ";start;attached"))
        #expect(early.remoteTmuxReport?.outcome == .new)
        early.feed(Array("\u{1B}]0;title\u{7}".utf8))
        early.feed(fail)
        #expect(early.remoteTmuxReport?.failureStatus == 9, "a title is not screen output")
        #expect(early.remoteTmuxReport?.reason == "bad")
        early.feed(Array("\u{1B}c".utf8))
        early.feed(signal(token.uuidString + ";start;attached"))
        #expect(early.remoteTmuxReport?.failureStatus == 9, "RIS cannot rearm a handshake")

        var cleared = Terminal()
        cleared.expectRemoteTmux(token: token)
        cleared.feed(new)
        cleared.feed(Array("\u{1B}[2J".utf8))
        cleared.feed(fail)
        #expect(cleared.remoteTmuxReport?.outcome == .new)
        #expect(cleared.remoteTmuxReport?.failureStatus == nil, "a clear is tmux on screen")

        var drawn = Terminal()
        drawn.expectRemoteTmux(token: token)
        drawn.feed(new)
        drawn.feed(Array("ready\r\n".utf8))
        drawn.feed(fail)
        #expect(drawn.remoteTmuxReport?.failureStatus == nil, "text after attach closes the failure window")

        var expired = Terminal()
        expired.expectRemoteTmux(token: token)
        expired.feed(new)
        expired.testingExpireRemoteTmuxAttachWindow()
        expired.feed(fail)
        #expect(expired.remoteTmuxReport?.failureStatus == nil, "a late fail is not an attach failure")

        var prepare = Terminal()
        prepare.expectRemoteTmux(token: token)
        prepare.feed(signal(token.uuidString + ";fail;4;626164"))
        #expect(prepare.remoteTmuxReport?.failureStatus == 4, "prepare failure has no start")

        var ordinary = Terminal()
        ordinary.feed(new)
        #expect(ordinary.remoteTmuxReport == nil)
        #expect(ordinary.takeOutput().isEmpty, "no output ever becomes input")
    }

    @Test func missingIsFinalAndMalformedReportsAreIgnored() {
        let token = UUID()
        var terminal = Terminal()
        terminal.expectRemoteTmux(token: token)
        for payload in ["fail;0;00", "fail;999;00", "fail;1;zz", "fail;1;0", "start;evil"] {
            terminal.feed(Array("\u{1B}]6973;\(token.uuidString);\(payload)\u{7}".utf8))
        }
        #expect(terminal.remoteTmuxReport?.failureStatus == nil)
        terminal.feed(Array("\u{1B}]6973;\(token.uuidString);start;missing\u{7}".utf8))
        terminal.feed(Array("\u{1B}]6973;\(token.uuidString);fail;1;00\u{7}".utf8))
        #expect(terminal.remoteTmuxReport?.outcome == .missing)
        #expect(terminal.remoteTmuxReport?.failureStatus == nil)
    }

    @Test func commandContainsOnlyCanonicalQuotedIdentitiesAndExactKill() {
        let id = UUID()
        let tmux = RemoteTmux(id: id)
        #expect(tmux.sessionName == "corta-" + id.uuidString.lowercased())
        #expect(tmux.killCommand == "tmux kill-session -t '=corta-\(id.uuidString.lowercased())'")
        #expect(!tmux.command.contains("kill-server"))
        #expect(!tmux.command.contains("source "))
        #expect(!tmux.command.contains("-CC"))
    }

    @Test(arguments: ["missing", "new", "attached", "prepare-failed", "attach-failed"])
    func wrapperBranchesAndZeroExitNeverStartsFallback(_ branch: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("corta-tmux-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("login-shell")
        try "#!/bin/sh\nprintf 'FALLBACK-LOGIN:%s\\n' \"$1\"\n".write(
            to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        if branch != "missing" {
            let fake = root.appendingPathComponent("tmux")
            try """
            #!/bin/sh
            case "$1" in
            new-session)
                case '\(branch)' in
                prepare-failed) echo 'broken tmux config' >&2; exit 7 ;;
                new) echo corta-created ;;
                *) exit 1 ;;
                esac ;;
            has-session)
                if [ '\(branch)' = prepare-failed ]; then exit 1; fi ;;
            attach-session)
                if [ '\(branch)' = attach-failed ]; then echo 'cannot attach' >&2; exit 8; fi ;;
            esac
            """.write(to: fake, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        }
        let tmux = RemoteTmux(id: UUID())
        var environment = ChildEnvironment.default()
        environment["PATH"] = root.path + ":/usr/bin:/bin"
        environment["SHELL"] = shell.path
        let pty = try PTY.spawn(executable: "/bin/sh", arguments: ["-c", tmux.command], environment: environment)
        defer { pty.close() }
        let output = pty.readOutput(timeout: testTimeout(5))
        var terminal = Terminal()
        terminal.expectRemoteTmux(token: tmux.token)
        terminal.feed(Array(output.utf8))
        let report = try #require(terminal.remoteTmuxReport)
        switch branch {
        case "missing": #expect(report.outcome == .missing)
        case "new": #expect(report.outcome == .new)
        case "attached": #expect(report.outcome == .attached)
        case "prepare-failed":
            #expect(report.failureStatus == 7)
            #expect(report.reason == "broken tmux config")
        default:
            #expect(report.outcome == .attached)
            #expect(report.failureStatus == 8)
            #expect(report.reason == "cannot attach")
        }
        #expect(output.contains("FALLBACK-LOGIN:-l") == ["missing", "prepare-failed", "attach-failed"].contains(branch))
    }
}
