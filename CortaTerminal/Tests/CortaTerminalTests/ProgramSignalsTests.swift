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

@Suite("Program signals")
struct ProgramSignalsTests {
    func osc(_ payload: String) -> [UInt8] { Array("\u{1B}]\(payload)\u{1B}\\".utf8) }

    @Test func probeAndSplitStatus() {
        var terminal = Terminal()
        for byte in osc("7501;?") { terminal.feed([byte]) }
        #expect(terminal.takeOutput() == osc("7501;?"))
        for byte in osc("7501;state=blocked:app=claude-code:id=task-1:kind=permission:progress=190:title=SGVsbG8=:msg=V29ybGQ=") { terminal.feed([byte]) }
        let status = terminal.programStatuses["task-1"]
        #expect(status?.state == .blocked)
        #expect(status?.progress == 100)
        #expect(status?.title == "Hello")
        #expect(status?.message == "World")
        #expect(status?.app == "claude-code")
        #expect(terminal.takeBlockedStatus()! == .permission)
        #expect(terminal.takeBlockedStatus() == nil)
        terminal.feed(osc("7501;state=blocked:id=task-1:kind=permission"))
        #expect(terminal.takeBlockedStatus() == nil)
        terminal.feed(osc("7501;state=clear:id=task-1"))
        #expect(terminal.programStatuses.isEmpty)
    }

    @Test func claude310CompletionReplacesWorkingBeforeProcessExit() {
        var terminal = Terminal()
        // Captured from a real Claude Code 2.1.310 turn. The agent process
        // stays alive and redraws its input prompt after reporting `done`.
        for state in ["idle", "working", "done"] {
            for byte in osc("7501;state=\(state):app=claude-code") { terminal.feed([byte]) }
            #expect(terminal.programStatuses[""]?.state == ProgramStatus.State(rawValue: state))
        }
        terminal.feed(Array("\u{1B}[2K\r❯ ".utf8))
        #expect(terminal.programStatuses[""]?.state == .done)
        terminal.feed(osc("7501;state=working:id=task-1"))
        terminal.feed(osc("7501;state=done:id=task-1"))
        #expect(terminal.programStatuses["task-1"]?.state == .done)
        terminal.feed(osc("7501;state=working"))
        #expect(terminal.programStatuses[""]?.state == .working)
    }

    @Test func doneIdleAndFailureRemainDistinctAcrossNotificationsAndClears() {
        var terminal = Terminal()
        terminal.feed(osc("7501;state=done:kind=permission"))
        terminal.feed(osc("9;Task finished"))
        #expect(terminal.programStatuses[""]?.state == .done)
        #expect(terminal.programStatuses[""]?.kind == nil)
        terminal.feed(osc("7501;state=idle"))
        #expect(terminal.programStatuses[""]?.state == .idle)
        terminal.feed(osc("7501;state=error"))
        #expect(terminal.programStatuses[""]?.state == .error)
        terminal.feed(osc("7501;state=clear"))
        #expect(terminal.programStatuses.isEmpty)
    }

    @Test func validationAndBounds() {
        var terminal = Terminal()
        for payload in ["state=unknown", "state=working:kind=unknown", "state=working:id=bad id", "state=working:id=" + String(repeating: "a", count: 33)] {
            terminal.feed(osc("7501;" + payload))
        }
        #expect(terminal.programStatuses.isEmpty)
        terminal.feed(osc("7501;state=idle:progress=-1:title=!!!:msg=YQ==garbage"))
        #expect(terminal.programStatuses[""]?.title == "")
        #expect(terminal.programStatuses[""]?.message == "")
        #expect(terminal.programStatuses[""]?.progress == 0)
        terminal.feed(osc("7501;state=clear"))
        for index in 0..<40 { terminal.feed(osc("7501;state=working:id=t\(index)")) }
        #expect(terminal.programStatuses.count == 32)
        terminal.feed(osc("7501;state=clear"))
        #expect(terminal.programStatuses.isEmpty)
        terminal.feed(osc("7501;state=working:title=" + Data(repeating: 65, count: 193).base64EncodedString()))
        #expect(terminal.programStatuses[""]?.title == "")
        let hostile = "hello\u{1B}\n\u{202E}world\u{200B}"
        #expect(ProgramText.clean(hostile, limit: 100) == "helloworld")
        #expect(ProgramText.clean("界界界", limit: 7) == "界界")
        terminal.reset()
        #expect(terminal.programStatuses.isEmpty)
    }

    @Test func notificationFamiliesAndConEmuRefusal() {
        var terminal = Terminal()
        terminal.feed(osc("9;Title: message"))
        #expect(terminal.takeDesktopNotification()?.body == "Title: message")
        #expect(terminal.takeDesktopNotification() == nil)
        terminal.feed(osc("777;notify;Title;body;rest"))
        let notice = terminal.takeDesktopNotification()
        #expect(notice?.title == "Title")
        #expect(notice?.body == "body;rest")
        terminal.feed(osc("777;unknown;a;b"))
        for code in [1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12] {
            terminal.feed(osc("9;\(code);touch /tmp/never-execute"))
        }
        #expect(terminal.takeDesktopNotification() == nil)
        #expect(terminal.takeOutput().isEmpty)
        for number in 1...4 {
            terminal.feed(osc("9;4;\(number);200"))
            #expect(terminal.programProgress?.state.rawValue == number)
            #expect(terminal.programProgress?.value == (number == 3 ? nil : 100))
        }
        terminal.feed(osc("9;4;0"))
        #expect(terminal.programProgress == nil)
    }

    @Test func kittyChunkingAndCapabilities() {
        var terminal = Terminal()
        terminal.feed(osc("99;i=safe-1:d=0:p=title;Hello"))
        #expect(terminal.takeDesktopNotification() == nil)
        terminal.feed(osc("99;i=safe-1:d=0:p=body:e=1;V29ybGQ="))
        terminal.feed(osc("99;i=safe-1:d=1:a=focus:o=unfocused:u=2:w=50:s=c3lzdGVt;"))
        let notice = terminal.takeDesktopNotification()
        #expect(notice?.title == "Hello")
        #expect(notice?.body == "World")
        #expect(notice?.occasion == .unfocused)
        #expect(notice?.urgency == 2)
        #expect(notice?.focus == true)
        #expect(notice?.expiryMilliseconds == 50)
        #expect(notice?.sound == true)
        terminal.feed(osc("99;i=safe-1:p=close;"))
        #expect(terminal.takeDesktopNotification()?.close == true)
        terminal.feed(osc("99;i=query-1:p=?;"))
        #expect(terminal.takeOutput() == osc("99;i=query-1:p=?;a=focus:o=always,unfocused,invisible:p=title,body,close,?:s=system,silent:w=1"))
        // All other input, including unsupported report/close/alive modes,
        // either produces no reply or precisely this constant + safe id.
        for payload in ["i=bad id:p=?;", "i=ab/c:p=?;", "i=" + String(repeating: "x", count: 33) + ":p=?;", "i=okay:p=alive;", "i=okay:a=report:c=1;body"] {
            terminal.feed(osc("99;" + payload))
            #expect(terminal.takeOutput().isEmpty)
        }
    }

    @Test func kittyRejectsOversizeAndRecovers() {
        var terminal = Terminal()
        for _ in 0..<3 { terminal.feed(osc("99;i=large:d=0;" + String(repeating: "x", count: 2000))) }
        terminal.feed(osc("99;i=large;tail"))
        #expect(terminal.takeDesktopNotification() == nil)
        terminal.feed(osc("99;i=large;recovered"))
        #expect(terminal.takeDesktopNotification()?.title == "recovered")
        terminal.feed(osc("99;i=bad:e=1;!bad"))
        #expect(terminal.takeDesktopNotification() == nil)
        for index in 0..<8 { terminal.feed(osc("99;i=c\(index):d=0;waiting")) }
        terminal.feed(osc("99;i=overflow;ignored"))
        #expect(terminal.takeDesktopNotification() == nil)
        terminal.feed(osc("99;i=c0:p=close;"))
        _ = terminal.takeDesktopNotification()
        terminal.feed(osc("99;i=recovery;okay"))
        #expect(terminal.takeDesktopNotification()?.title == "okay")
        terminal.feed(osc("9;" + String(repeating: "x", count: 5000)))
        #expect(terminal.takeDesktopNotification() == nil)
        terminal.feed(osc("9;after"))
        #expect(terminal.takeDesktopNotification()?.body == "after")
    }

    @Test func tabStatusEscapesAndClear() {
        var terminal = Terminal()
        terminal.feed(osc("21337;indicator=#00ff00;status=Hello\\; world\\\\!;status-color=#ffffff"))
        #expect(terminal.programStatuses["tab-status"]?.title == "Hello; world\\!")
        #expect(terminal.programStatuses["tab-status"]?.state == .unknown)
        #expect(terminal.programStatuses["tab-status"]?.color == "#00ff00")
        terminal.feed(osc("21337;indicator=;status=;status-color="))
        #expect(terminal.programStatuses.isEmpty)
    }
}
