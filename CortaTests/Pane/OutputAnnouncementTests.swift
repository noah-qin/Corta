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

import CortaTerminal
import Foundation
import Testing

@testable import Corta

/// What VoiceOver is told when a command finishes: the wording, the bounds
/// and the rate limit, driven with real OSC 133 marks and a fixed clock.
///
/// The listening pass that says what VoiceOver already speaks (#359) is
/// human-only; these tests cover the rule that builds what it would hear,
/// not the hearing itself.
struct OutputAnnouncementTests {
    /// One command a test session runs: its line, its output rows and its
    /// status.
    private struct Run {
        var command: String
        var output: [String]
        var status: Int
    }

    /// A session driven the way a shell with Corta's integration drives it:
    /// `A` at each prompt, `C` where output starts, `D;status` when a
    /// command finishes.
    private static func session(
        _ runs: [Run], rows: Int = 24, columns: Int = 40, scrollbackLimit: Int = 500
    ) -> (terminal: Terminal, finished: [CommandRecord]) {
        var terminal = Terminal(rows: rows, columns: columns, scrollbackLimit: scrollbackLimit)
        for run in runs {
            terminal.feed(Array("\u{1B}]133;A\u{7}$ \(run.command)\r\n".utf8))
            terminal.feed(Array("\u{1B}]133;C\u{7}".utf8))
            for line in run.output { terminal.feed(Array("\(line)\r\n".utf8)) }
            terminal.feed(Array("\u{1B}]133;D;\(run.status)\u{7}".utf8))
        }
        // The prompt now waiting for input starts the next, unfinished record.
        terminal.feed(Array("\u{1B}]133;A\u{7}$ ".utf8))
        return (terminal, terminal.commandRecords.records.filter { !$0.isRunning })
    }

    private static func announcement(
        _ policy: inout OutputAnnouncementPolicy, terminal: Terminal, record: CommandRecord,
        exitStatus: Int, isAlternateScreen: Bool = false, now: TimeInterval = 100
    ) -> String? {
        policy.announcement(
            grid: terminal.grid, record: record, exitStatus: exitStatus,
            isAlternateScreen: isAlternateScreen, now: now)
    }

    @Test func shortOutputIsAnnouncedInFull() throws {
        let (terminal, finished) = Self.session([
            Run(command: "seq 1 5", output: ["1", "2", "3", "4", "5"], status: 0),
        ])
        let record = try #require(finished.last)
        var policy = OutputAnnouncementPolicy()
        #expect(
            Self.announcement(&policy, terminal: terminal, record: record, exitStatus: 0)
                == "1\n2\n3\n4\n5")
    }

    /// The typed command is echo, not output: it sits above the `C` mark, so
    /// hearing the announcement never repeats what typing already said.
    @Test func theTypedCommandLineIsNotReadBack() throws {
        let (terminal, finished) = Self.session([
            Run(command: "echo hello", output: ["hello"], status: 0),
        ])
        let record = try #require(finished.last)
        var policy = OutputAnnouncementPolicy()
        let spoken = Self.announcement(&policy, terminal: terminal, record: record, exitStatus: 0)
        #expect(spoken == "hello")
        #expect(spoken?.contains("echo hello") == false)
    }

    /// A successful command that printed nothing did not happen, as far as a
    /// listener is concerned.
    @Test func aSilentSuccessSaysNothing() throws {
        let (terminal, finished) = Self.session([Run(command: "true", output: [], status: 0)])
        let record = try #require(finished.last)
        var policy = OutputAnnouncementPolicy()
        #expect(Self.announcement(&policy, terminal: terminal, record: record, exitStatus: 0) == nil)
    }

    /// A failure is the one thing a silent command has to say.
    @Test func aSilentFailureAnnouncesItsExitStatus() throws {
        let (terminal, finished) = Self.session([Run(command: "false", output: [], status: 2)])
        let record = try #require(finished.last)
        var policy = OutputAnnouncementPolicy()
        #expect(
            Self.announcement(&policy, terminal: terminal, record: record, exitStatus: 2)
                == L10n.format("a11y.command.failed", 2))
    }

    @Test func aFailureWithOutputAppendsItsExitStatus() throws {
        let (terminal, finished) = Self.session([
            Run(command: "boom", output: ["boom"], status: 1),
        ])
        let record = try #require(finished.last)
        var policy = OutputAnnouncementPolicy()
        #expect(
            Self.announcement(&policy, terminal: terminal, record: record, exitStatus: 1)
                == "boom\n" + L10n.format("a11y.command.failed", 1))
    }

    /// A flood such as `yes` is one bounded sentence, not the stream.
    @Test func outputTooLongToHearIsSummarised() throws {
        let (terminal, finished) = Self.session([
            Run(command: "yes", output: (0..<40).map { "line \($0)" }, status: 130),
        ])
        let record = try #require(finished.last)
        var policy = OutputAnnouncementPolicy()
        let spoken = Self.announcement(&policy, terminal: terminal, record: record, exitStatus: 130)
        #expect(spoken == L10n.text("a11y.command.outputTooLong") + "\n"
            + L10n.format("a11y.command.failed", 130))
    }

    /// Few rows, many characters: the character bound is the other half of
    /// "bounded in length".
    @Test func aLongSingleRowIsSummarisedByCharacters() throws {
        let (terminal, finished) = Self.session(
            [Run(command: "long", output: [String(repeating: "x", count: 150)], status: 0)],
            rows: 24, columns: 200)
        let record = try #require(finished.last)
        var policy = OutputAnnouncementPolicy(maximumRows: 8, maximumCharacters: 100)
        #expect(
            Self.announcement(&policy, terminal: terminal, record: record, exitStatus: 0)
                == L10n.text("a11y.command.outputTooLong"))
    }

    @Test func theAlternateScreenIsLeftSilent() throws {
        let (terminal, finished) = Self.session([
            Run(command: "vim", output: ["file"], status: 0),
        ])
        let record = try #require(finished.last)
        var policy = OutputAnnouncementPolicy()
        #expect(
            Self.announcement(
                &policy, terminal: terminal, record: record, exitStatus: 0,
                isAlternateScreen: true) == nil)
    }

    /// A full-screen program's silence must not use up the interval for the
    /// command that follows it.
    @Test func alternateScreenSilenceDoesNotConsumeTheRateLimit() throws {
        let (terminal, finished) = Self.session([
            Run(command: "vim", output: ["file"], status: 0), Run(command: "ls", output: ["a"], status: 0),
        ])
        let vim = try #require(finished.first)
        let list = try #require(finished.last)
        var policy = OutputAnnouncementPolicy()
        #expect(
            Self.announcement(
                &policy, terminal: terminal, record: vim, exitStatus: 0, isAlternateScreen: true,
                now: 100) == nil)
        #expect(Self.announcement(&policy, terminal: terminal, record: list, exitStatus: 0, now: 100) == "a")
    }

    /// A burst of commands finishing together says one thing; the rest are
    /// dropped rather than queued behind the speech already under way.
    @Test func announcementsInsideTheIntervalAreDroppedNotQueued() throws {
        let (terminal, finished) = Self.session([
            Run(command: "one", output: ["one"], status: 0), Run(command: "two", output: ["two"], status: 0),
            Run(command: "three", output: ["three"], status: 0),
        ])
        let one = try #require(finished.first)
        let two = try #require(finished.dropFirst().first)
        let three = try #require(finished.last)
        var policy = OutputAnnouncementPolicy(minimumInterval: 2)
        #expect(Self.announcement(&policy, terminal: terminal, record: one, exitStatus: 0, now: 10) == "one")
        #expect(Self.announcement(&policy, terminal: terminal, record: two, exitStatus: 0, now: 11) == nil)
        #expect(
            Self.announcement(&policy, terminal: terminal, record: three, exitStatus: 0, now: 12)
                == "three")
    }

    /// Output from an earlier command is not part of this command's
    /// announcement.
    @Test func onlyTheFinishedCommandsOutputIsAnnounced() throws {
        let (terminal, finished) = Self.session([
            Run(command: "first", output: ["old output"], status: 0),
            Run(command: "second", output: ["new output"], status: 0),
        ])
        let record = try #require(finished.last)
        var policy = OutputAnnouncementPolicy()
        #expect(
            Self.announcement(&policy, terminal: terminal, record: record, exitStatus: 0)
                == "new output")
    }
}
