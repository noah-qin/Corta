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
        #expect(terminal.takeDesktopNotification() == nil)
        #expect(terminal.takeClosedNotificationIDs() == ["safe-1"])
        // Closing one id between reads never swallows another id's notice;
        // closing the pending id itself drops it.
        terminal.feed(osc("99;i=B;new message") + osc("99;i=A:p=close;"))
        #expect(terminal.takeDesktopNotification()?.title == "new message")
        #expect(terminal.takeClosedNotificationIDs() == ["A"])
        terminal.feed(osc("99;i=C;retracted") + osc("99;i=C:p=close;"))
        #expect(terminal.takeDesktopNotification() == nil)
        #expect(terminal.takeClosedNotificationIDs() == ["C"])
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
        // Eight abandoned messages never shut out a ninth: the stalest goes.
        for index in 0..<8 { terminal.feed(osc("99;i=c\(index):d=0;waiting")) }
        terminal.feed(osc("99;i=overflow;delivered"))
        #expect(terminal.takeDesktopNotification()?.title == "delivered")
        terminal.feed(osc("99;i=c0;finished"))
        #expect(terminal.takeDesktopNotification()?.title == "finished")
        terminal.feed(osc("99;i=c7;finished"))
        #expect(terminal.takeDesktopNotification()?.title == "waitingfinished")
        for index in 0..<20 { terminal.feed(osc("99;i=s\(index):d=0;stale")) }
        terminal.feed(osc("99;i=recovery;okay"))
        #expect(terminal.takeDesktopNotification()?.title == "okay")
        terminal.feed(osc("9;" + String(repeating: "x", count: 5000)))
        #expect(terminal.takeDesktopNotification() == nil)
        terminal.feed(osc("9;after"))
        #expect(terminal.takeDesktopNotification()?.body == "after")
    }

    // Wire shapes independently transcribed from the installed 2.1.310
    // emitters (WDr/pD), not captured model sessions. Its normal terminator
    // is BEL; terminal identification as kitty selects ST instead.
    @Test func claude310WireFormatsAndTerminators() {
        for end in ["\u{7}", "\u{1B}\\"] {
            func wire(_ payload: String) -> [UInt8] { Array(("\u{1B}]" + payload + end).utf8) }
            var terminal = Terminal()
            terminal.feed(wire("7501;?"))
            #expect(terminal.takeOutput() == osc("7501;?"))
            for state in ["idle", "working", "done", "idle", "error"] {
                for byte in wire("7501;state=\(state):app=claude-code") { terminal.feed([byte]) }
                #expect(terminal.programStatuses[""]?.state.rawValue == state)
            }
            for kind in ["permission", "question", "auth"] {
                terminal.feed(wire("7501;state=blocked:app=claude-code:kind=\(kind):msg=TmVlZHMgaW5wdXQ="))
                #expect(terminal.programStatuses[""]?.kind?.rawValue == kind)
                #expect(terminal.programStatuses[""]?.message == "Needs input")
            }
            terminal.feed(wire("7501;state=blocked:app=claude-code"))
            #expect(terminal.programStatuses[""]?.kind == nil)
            terminal.feed(wire("7501;state=working:app=claude-code:id=child-1"))
            terminal.feed(wire("7501;state=clear:id=child-1"))
            #expect(terminal.programStatuses.count == 1)
            terminal.feed(wire("7501;state=clear"))
            #expect(terminal.programStatuses.isEmpty)
            terminal.feed(wire("9;Permission needed: Claude needs your permission"))
            #expect(terminal.takeDesktopNotification()?.body == "Permission needed: Claude needs your permission")
            terminal.feed(wire("777;notify;Permission needed;Claude needs your permission"))
            let ghostty = terminal.takeDesktopNotification()
            #expect(ghostty?.title == "Permission needed")
            #expect(ghostty?.body == "Claude needs your permission")
            // The real body packet omits d=0. It completes the message;
            // Claude then emits an empty final focus packet. No second notice.
            terminal.feed(wire("99;i=409:d=0:p=title;Permission needed"))
            #expect(terminal.takeDesktopNotification() == nil)
            terminal.feed(wire("99;i=409:p=body;Claude needs your permission"))
            let kitty = terminal.takeDesktopNotification()
            #expect(kitty?.title == "Permission needed")
            #expect(kitty?.body == "Claude needs your permission")
            #expect(kitty?.occasion == .always)
            terminal.feed(wire("99;i=409:d=1:a=focus;"))
            #expect(terminal.takeDesktopNotification() == nil)
            #expect(terminal.takeOutput().isEmpty)
        }
    }

    @Test func mainSlotSurvivesThirtyTwoSubtasksInEitherOrder() {
        for mainFirst in [true, false] {
            var terminal = Terminal()
            if mainFirst { terminal.feed(osc("7501;state=done:app=claude-code")) }
            for id in 0..<32 { terminal.feed(osc("7501;state=working:app=claude-code:id=c\(id)")) }
            if !mainFirst { terminal.feed(osc("7501;state=done:app=claude-code")) }
            terminal.feed(osc("7501;state=working:id=overflow"))
            #expect(terminal.programStatuses.count == ProgramStatus.maximumEntries)
            #expect(terminal.programStatuses["overflow"] == nil)
            for id in 0..<31 { terminal.feed(osc("7501;state=clear:id=c\(id)")) }
            #expect(terminal.programStatuses["c31"]?.state == .working)
            terminal.feed(osc("7501;state=clear:id=c31"))
            #expect(terminal.programStatuses[""]?.state == .done)
        }
    }

    @Test func shellBoundaryEndsCrashedProgramAndClearsChildrenAndProgress() {
        for (exit, expected) in [(0, ProgramStatus.State.idle), (130, .idle), (137, .error)] {
            var terminal = Terminal()
            terminal.feed(osc("133;A") + osc("133;C"))
            terminal.feed(osc("7501;state=blocked:kind=permission") + osc("7501;state=working:id=child"))
            terminal.feed(osc("9;4;1;50") + osc("21337;indicator=#00ff00;status=Old"))
            terminal.feed(osc("133;D;\(exit)") + osc("133;A"))
            #expect(terminal.programStatuses.count == 1)
            #expect(terminal.programStatuses[""]?.state == expected)
            #expect(terminal.programStatuses[""]?.kind == nil)
            #expect(terminal.programProgress == nil)
            #expect(terminal.programTabMetadata == nil)
            #expect(terminal.takeBlockedStatus() == nil)
            terminal.feed(osc("133;C"))
            #expect(terminal.programStatuses.isEmpty)
        }
        for state in ["done", "error"] {
            var terminal = Terminal()
            terminal.feed(osc("133;A") + osc("133;C") + osc("7501;state=\(state)"))
            terminal.feed(osc("133;D;0"))
            #expect(terminal.programStatuses[""]?.state.rawValue == state)
        }
    }

    @Test func killedAlternateScreenProgramCannotLeaveWaitingAtShellBoundary() {
        var terminal = Terminal()
        terminal.feed(osc("133;A") + osc("133;C"))
        terminal.feed(Array("\u{1B}[?1049h".utf8))
        terminal.feed(osc("7501;state=blocked:kind=permission") + osc("7501;state=working:id=child"))
        terminal.feed(osc("9;4;1;40") + osc("133;D;137"))
        // Held until the shell's own prompt confirms the child is gone.
        #expect(terminal.isCommandRunning)
        terminal.feed(osc("7;file://host/tmp") + osc("133;A"))
        #expect(terminal.grid.isAlternateScreenActive)
        #expect(terminal.grid.promptRows.isEmpty)
        #expect(!terminal.isCommandRunning)
        #expect(terminal.commandRecords.lastCompleted?.exitStatus == 137)
        #expect(terminal.programStatuses.count == 1)
        #expect(terminal.programStatuses[""]?.state == .error)
        #expect(terminal.programStatuses[""]?.kind == nil)
        #expect(terminal.programProgress == nil)
        #expect(terminal.takeBlockedStatus() == nil)
    }

    @Test func strayFinishFromALiveAlternateScreenProgramIsInert() {
        var terminal = Terminal()
        terminal.feed(osc("133;A") + osc("133;C"))
        terminal.feed(Array("\u{1B}[?1049h\u{1B}[?2004h\u{1B}[>1u".utf8))
        terminal.feed(osc("7501;state=working"))
        // A log shown by `less -R` carrying a finished mark, not the shell's.
        terminal.feed(osc("133;D;0"))
        #expect(terminal.isCommandRunning)
        #expect(terminal.isBracketedPasteEnabled)
        #expect(terminal.keyboardEnhancements.rawValue == 1)
        #expect(terminal.programStatuses[""]?.state == .working)
        // The program leaves normally; the stale mark cannot finish later.
        terminal.feed(Array("\u{1B}[<u\u{1B}[?1049l".utf8))
        terminal.feed(Array("\u{1B}[?1049h".utf8) + osc("133;A"))
        #expect(terminal.isCommandRunning)
    }

    @Test func coalescedWaitingEpisodesRemainDistinctButKindUpdatesDoNot() {
        var terminal = Terminal()
        terminal.feed(osc("7501;state=blocked:kind=permission"))
        #expect(terminal.programBlockedEpisode == 1)
        terminal.feed(osc("7501;state=blocked:kind=question"))
        #expect(terminal.programBlockedEpisode == 1)
        terminal.feed(osc("7501;state=working") + osc("7501;state=blocked:kind=permission"))
        #expect(terminal.programBlockedEpisode == 2)
        terminal.feed(osc("7501;state=clear") + osc("7501;state=blocked:id=child"))
        #expect(terminal.programBlockedEpisode == 3)
        // RIS clears the state but never reuses an announced episode number.
        terminal.feed(Array("\u{1B}c".utf8) + osc("7501;state=blocked:kind=permission"))
        #expect(terminal.programBlockedEpisode == 4)
        terminal.feed(osc("133;C"))
        terminal.feed(osc("7501;state=working"))
        terminal.feed(osc("133;C")) // duplicate output marker, same command
        #expect(terminal.programStatuses[""]?.state == .working)
    }

    @Test func capturedClaude310LifecycleSignals() throws {
        struct Capture: Decodable {
            struct Scenario: Decodable { var expected: String; var wire: [String] }
            var version: String
            var scenarios: [String: Scenario]
        }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Golden/claude-2.1.310-signals.json")
        let capture = try JSONDecoder().decode(Capture.self, from: Data(contentsOf: path))
        #expect(capture.version == "2.1.310")
        for (name, scenario) in capture.scenarios {
            var terminal = Terminal()
            var children = Set<String>()
            var states = Set<String>()
            for sequence in scenario.wire {
                for byte in sequence.utf8 { terminal.feed([byte]) }
                children.formUnion(terminal.programStatuses.keys.filter { !$0.isEmpty })
                if let state = terminal.programStatuses[""]?.state { states.insert(state.rawValue) }
            }
            #expect(terminal.programStatuses[""]?.state.rawValue == scenario.expected, "captured \(name)")
            if name == "cancel" { #expect(states.contains("blocked")); #expect(!states.contains("done")) }
            if name == "auth" { #expect(terminal.programStatuses[""]?.kind == .auth) }
            if name == "subtask" { #expect(!children.isEmpty); #expect(terminal.programStatuses.count == 1) }
            if name == "crash" { #expect(!terminal.isCommandRunning); #expect(terminal.programStatuses[""]?.kind == nil) }
        }
    }

    @Test func capturedClaude310NotificationsDeliverOneMessageWithoutChangingTaskState() throws {
        struct Capture: Decodable { var notifications: [String: [String]] }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Golden/claude-2.1.310-signals.json")
        let capture = try JSONDecoder().decode(Capture.self, from: Data(contentsOf: path))
        #expect(Set(capture.notifications.keys) == ["iterm2", "ghostty", "kitty"])
        for (channel, packets) in capture.notifications {
            var terminal = Terminal()
            terminal.feed(osc("7501;state=done:app=claude-code"))
            var notices: [DesktopNotification] = []
            for packet in packets {
                for byte in packet.utf8 { terminal.feed([byte]) }
                if let notice = terminal.takeDesktopNotification() { notices.append(notice) }
            }
            #expect(notices.count == 1, "captured \(channel)")
            #expect(notices.first?.body == "Claude is waiting for your input")
            #expect(notices.first?.title == (channel == "iterm2" ? "" : "Claude Code"))
            #expect(notices.first?.occasion == (channel == "kitty" ? .always : .invisible))
            #expect(terminal.programStatuses[""]?.state == .done)
            let rang = terminal.takeBell()
            #expect(!rang, "OSC's BEL terminator is not a bell event")
            #expect(terminal.takeOutput().isEmpty)
        }
    }

    @Test func tabStatusEscapesAndClear() {
        var terminal = Terminal()
        terminal.feed(osc("21337;indicator=#00ff00;status=Hello\\; world\\\\!;status-color=#ffffff"))
        #expect(terminal.programTabMetadata?.title == "Hello; world\\!")
        #expect(terminal.programTabMetadata?.state == .unknown)
        #expect(terminal.programTabMetadata?.color == "#00ff00")
        terminal.feed(osc("21337;indicator=;status=;status-color="))
        #expect(terminal.programStatuses.isEmpty)
    }
}
