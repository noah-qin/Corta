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

/// OSC 7501 against the Program Status Protocol, revision 0.4, through a real
/// PTY: `/bin/cat` echoes each report back to the terminal as output. What Corta
/// deliberately does differently is in `CONFORMANCE.md`, and pinned here too.
struct ProgramStatusConformanceTests {
    private func report(_ payload: String) -> String { "\u{1B}]7501;\(payload)\u{1B}\\" }
    private func mark(_ payload: String) -> String { "\u{1B}]133;\(payload)\u{1B}\\" }

    /// Feeds through the PTY and waits for the sentinel title to arrive after it.
    private func feed(_ session: TerminalSession, _ text: String) async throws {
        let sentinel = UUID().uuidString
        session.write(Array((text + "\u{1B}]2;" + sentinel + "\u{1B}\\\n").utf8))
        let deadline = SuspendingClock.now + testTimeout(10)
        while session.windowTitle != sentinel, SuspendingClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10), clock: .suspending)
        }
        try #require(session.windowTitle == sentinel)
    }

    private func withSession(_ body: (TerminalSession) async throws -> Void) async throws {
        let session = try TerminalSession(executable: "/bin/cat", arguments: [],
            environment: ChildEnvironment.default(), workingDirectory: "/")
        session.start()
        defer { session.stop() }
        try await body(session)
    }

    @Test("a new prompt drops working and blocked, and keeps done and error")
    func promptDropsWhatIsNoLongerTrue() async throws {
        try await withSession { session in
            try await feed(session, report("state=working:id=w") + report("state=blocked:kind=auth:id=b")
                + report("state=done:id=d") + report("state=error:id=e") + report("state=idle:id=i"))
            #expect(session.programStatuses.count == 5)
            try await feed(session, mark("A"))
            let left = session.programStatuses
            #expect(left["w"] == nil)
            #expect(left["b"] == nil)
            #expect(left["d"]?.state == .done)
            #expect(left["e"]?.state == .error)
        }
    }

    @Test("a reported wait at a prompt with no command around it ends at the next prompt")
    func promptWithoutACommand() async throws {
        try await withSession { session in
            try await feed(session, mark("A") + mark("B") + report("state=blocked:kind=question"))
            #expect(session.programStatuses[""]?.state == .blocked)
            try await feed(session, mark("A"))
            #expect(session.programStatuses[""] == nil)
        }
    }

    @Test("a crashed program's states end at the shell's marks, in order D then A")
    func finishThenPrompt() async throws {
        try await withSession { session in
            try await feed(session, mark("A") + mark("B") + mark("C") + report("state=working"))
            try await feed(session, mark("D;137") + mark("A"))
            #expect(session.programStatuses[""]?.state == .error)
            try await feed(session, report("state=done"))
            try await feed(session, mark("A"))
            #expect(session.programStatuses[""]?.state == .done)
        }
    }

    /// Another precmd hook can run first, so the prompt arrives before the finish.
    @Test("a prompt before the finish still lets a failing exit read as failed")
    func promptBeforeFinish() async throws {
        try await withSession { session in
            try await feed(session, mark("A") + mark("B") + mark("C") + report("state=working"))
            try await feed(session, mark("A"))
            #expect(session.programStatuses.isEmpty)
            try await feed(session, mark("D;1"))
            #expect(session.programStatuses[""]?.state == .error)
            try await feed(session, mark("A") + mark("B") + mark("C") + report("state=blocked"))
            try await feed(session, mark("A") + mark("D;0"))
            #expect(session.programStatuses[""]?.state == .idle)
            // The same with a finished child beside it, in either hook order.
            for finish in [mark("A") + mark("D;0"), mark("D;0") + mark("A")] {
                try await feed(session, mark("A") + mark("B") + mark("C")
                    + report("state=done:id=child") + report("state=working"))
                try await feed(session, finish)
                #expect(session.programStatuses[""]?.state == .idle)
            }
        }
    }

    @Test("OSC 9;4 never changes a reported state")
    func progressLeavesStateAlone() async throws {
        try await withSession { session in
            let why = Data("why".utf8).base64EncodedString()
            try await feed(session, report("state=blocked:kind=permission:msg=" + why))
            try await feed(session, "\u{1B}]9;4;1;50\u{1B}\\")
            let status = session.programStatuses[""]
            #expect(status?.state == .blocked)
            #expect(status?.kind == .permission)
            #expect(status?.message == "why")
            #expect(session.programProgress?.value == 50, "a separate ring, not the record")
            try await feed(session, "\u{1B}]9;4;0\u{1B}\\")
            #expect(session.programStatuses[""]?.state == .blocked)
        }
    }

    @Test("past the cap the least recently updated child goes, never the root")
    func evictionTakesTheStalest() async throws {
        try await withSession { session in
            try await feed(session, report("state=working"))
            for index in 0..<ProgramStatus.maximumSubtasks {
                try await feed(session, report("state=working:id=t\(index)"))
            }
            // Touched, so t1 is now the stalest.
            try await feed(session, report("state=idle:id=t0"))
            try await feed(session, report("state=blocked:kind=question:id=new"))
            let statuses = session.programStatuses
            #expect(statuses.count == ProgramStatus.maximumEntries)
            #expect(statuses["new"]?.state == .blocked, "a new wait is never refused")
            #expect(statuses["t1"] == nil)
            #expect(statuses["t0"] != nil)
            #expect(statuses[""] != nil)
        }
    }

    @Test("clear removes the record and everything beneath it, and nothing that merely starts alike")
    func clearRemovesTheSubtree() async throws {
        try await withSession { session in
            for id in ["a", "a/b", "a/b/c", "ab"] { try await feed(session, report("state=working:id=\(id)")) }
            #expect(session.programStatuses.count == 4)
            try await feed(session, report("state=clear:id=a"))
            #expect(Set(session.programStatuses.keys) == ["ab"])
            try await feed(session, report("state=clear"))
            #expect(session.programStatuses.isEmpty)
        }
    }

    @Test("an id must fit the grammar: segments, depth and length")
    func idGrammar() async throws {
        try await withSession { session in
            let longSegment = String(repeating: "x", count: 33)
            let deep = Array(repeating: "a", count: 9).joined(separator: "/")
            let long = Array(repeating: String(repeating: "x", count: 32), count: 4).joined(separator: "/") + "/y"
            for id in [longSegment, deep, long, "a//b", "/a", "a/", "a b", "a$b"] {
                try await feed(session, report("state=working:id=\(id)"))
            }
            #expect(session.programStatuses.isEmpty)
            let deepest = Array(repeating: "a", count: 8).joined(separator: "/")
            try await feed(session, report("state=working:id=\(deepest)"))
            #expect(session.programStatuses[deepest]?.state == .working)
        }
    }

    @Test("an unknown kind counts as absent, an unknown state drops the report, unknown keys are ignored")
    func extensibility() async throws {
        try await withSession { session in
            try await feed(session, report("state=blocked:kind=payment:future=1"))
            #expect(session.programStatuses[""]?.state == .blocked)
            #expect(session.programStatuses[""]?.kind == nil)
            try await feed(session, report("state=sleeping"))
            #expect(session.programStatuses[""]?.state == .blocked)
            try await feed(session, report("nostate=1"))
            #expect(session.programStatuses[""]?.state == .blocked)
        }
    }

    @Test("whitespace around keys and values is removed, and the last of a repeated key wins")
    func spacingAndRepeats() async throws {
        try await withSession { session in
            try await feed(session, report(" state = working : id = a : state = done "))
            #expect(session.programStatuses["a"]?.state == .done)
        }
    }

    @Test("progress belongs to working and blocked")
    func progressOnlyWhereItMeansSomething() async throws {
        try await withSession { session in
            try await feed(session, report("state=working:progress=40"))
            #expect(session.programStatuses[""]?.progress == 40)
            try await feed(session, report("state=done:progress=40"))
            #expect(session.programStatuses[""]?.progress == nil)
        }
    }

    @Test("a report replaces its record whole")
    func replacement() async throws {
        try await withSession { session in
            try await feed(session, report("state=blocked:kind=auth:app=x:progress=5"))
            try await feed(session, report("state=working"))
            let status = session.programStatuses[""]
            #expect(status?.kind == nil)
            #expect(status?.app == "")
            #expect(status?.progress == nil)
        }
    }

    /// A deliberate difference (`CONFORMANCE.md`): the state still shows, with
    /// the text cleaned, because losing a wait costs more than a stripped newline.
    @Test("controls in text are removed and the state kept; undecodable text is left out")
    func textIsCleanedRatherThanRefused() async throws {
        try await withSession { session in
            let hostile = Data("one\ntwo\u{1B}[31m\u{202E}".utf8).base64EncodedString()
            try await feed(session, report("state=blocked:msg=\(hostile)"))
            #expect(session.programStatuses[""]?.state == .blocked)
            let message = session.programStatuses[""]?.message ?? "\n"
            #expect(!message.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || $0 == "\u{202E}" })
            try await feed(session, report("state=working:msg=@@@not-base64"))
            #expect(session.programStatuses[""]?.state == .working)
            #expect(session.programStatuses[""]?.message == "")
        }
    }

    @Test("a full reset removes every record, a soft reset none, and the alternate screen is no boundary")
    func resets() async throws {
        try await withSession { session in
            try await feed(session, report("state=working"))
            try await feed(session, "\u{1B}[?1049h")
            #expect(session.programStatuses[""]?.state == .working)
            try await feed(session, "\u{1B}[?1049l\u{1B}[!p")
            #expect(session.programStatuses[""]?.state == .working)
            try await feed(session, "\u{1B}c")
            #expect(session.programStatuses.isEmpty)
        }
    }

    @Test("the probe gets the one constant reply")
    func probe() async throws {
        var terminal = Terminal()
        terminal.feed(Array("\u{1B}]7501;?\u{1B}\\".utf8))
        #expect(terminal.takeOutput() == Array("\u{1B}]7501;?\u{1B}\\".utf8))
    }
}
