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

import Testing
@testable import CortaTerminal

struct DirectoryCompletionTests {
    @Test func boundedDisplayOnlyProtocol() {
        let state = DirectoryCompletion(payload: "12;1;Alpha/;%E7%A9%BA%E6%A0%BC%20%E4%B8%AD%E6%96%87/")
        #expect(state?.candidates == ["Alpha/", "空格 中文/"])
        #expect(state?.selectedIndex == 1)
        #expect(DirectoryCompletion(payload: "1;0;bad%0Aname/") == nil)
        #expect(DirectoryCompletion(payload: "1;0;bad%1Bname/") == nil)
        #expect(DirectoryCompletion(payload: "1;2;only/") == nil)
        #expect(DirectoryCompletion(payload: "1;0;bad%ZZ/") == nil)
        #expect(DirectoryCompletion(payload: "1;0" )?.candidates == [])
        #expect(DirectoryCompletion(payload: "1;0" + String(repeating: ";a/", count: 21)) == nil)
    }
    @Test func runningAndAlternateScreenCannotOfferDirectories() {
        var terminal = Terminal(rows: 5, columns: 60)
        terminal.directoryCompletionToken = "k"
        terminal.feed(Array("\u{1b}]133;A\u{7}\u{1b}]133;B\u{7}\u{1b}]134;k;1;0;Alpha/\u{7}".utf8))
        #expect(terminal.directoryCompletion?.candidates == ["Alpha/"])
        terminal.feed(Array("\u{1b}]133;C\u{7}\u{1b}]134;k;2;0;Other/\u{7}".utf8))
        #expect(terminal.directoryCompletion == nil)
    }
    @Test func interruptionSurvivesDisabledHistoryAndScreenChanges() {
        var terminal = Terminal(rows: 5, columns: 60, commandHistoryLimit: 0)
        terminal.directoryCompletionToken = "k"
        terminal.feed(Array("\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}sleep 10\r\n\u{1b}]133;C\u{7}\u{1b}]133;D;130\u{7}".utf8))
        #expect(terminal.grid.line(0).mark == .promptInterrupted)
        terminal.feed(Array("\u{1b}]133;A\u{7}\u{1b}]133;B\u{7}\u{1b}]134;k;1;0;Alpha/\u{7}".utf8))
        #expect(terminal.directoryCompletion?.candidates == ["Alpha/"])
        terminal.feed(Array("\u{1b}[?1049h\u{1b}]134;k;2;0;Other/\u{7}\u{1b}[?1049l".utf8))
        #expect(terminal.directoryCompletion == nil)
    }

    /// Output — a `cat`ted file, a remote shell over ssh — can forge the
    /// prompt marks but not the pane's token, and the overlay it would show
    /// takes Tab and the arrows.
    @Test func onlyTheShellsOwnReportIsBelieved() {
        func report(_ token: String) -> [UInt8] {
            Array("\u{1b}]133;D;0\u{7}\u{1b}]133;A\u{7}\u{1b}]133;B\u{7}\u{1b}]134;\(token)1;0;p=;Alpha/\u{7}".utf8)
        }
        var untrusting = Terminal(rows: 5, columns: 60)
        untrusting.feed(report(""))
        #expect(untrusting.directoryCompletion == nil)
        var terminal = Terminal(rows: 5, columns: 60)
        terminal.directoryCompletionToken = "secret"
        terminal.feed(report(""))
        #expect(terminal.directoryCompletion == nil)
        terminal.feed(report("guess;"))
        #expect(terminal.directoryCompletion == nil)
        terminal.feed(report("secre;"))
        #expect(terminal.directoryCompletion == nil)
        terminal.feed(report("secret;"))
        #expect(terminal.directoryCompletion?.candidates == ["Alpha/"])
        terminal.feed(Array("\u{1b}c".utf8))
        terminal.feed(report("secret;"))
        #expect(terminal.directoryCompletion?.candidates == ["Alpha/"], "a reset keeps the token")
    }

    @Test func concealingScalarsInNamesAreShown() {
        let state = DirectoryCompletion(payload: "1;0;p=a%E2%80%AE;a%E2%80%AEb%E2%80%8B/")
        #expect(state?.candidates == ["a\u{FFFD}b\u{FFFD}/"])
        #expect(state?.previewSuffix == "b\u{FFFD}/")
    }

    @Test func ghostPreviewOnlyContainsTheUnwrittenSuffix() {
        #expect(DirectoryCompletion(payload: "1;0;p=Al;Alpha/")?.previewSuffix == "pha/")
        #expect(DirectoryCompletion(payload: "2;0;p=%E7%A9%BA;%E7%A9%BA%E6%A0%BC/")?.previewSuffix == "格/")
        #expect(DirectoryCompletion(payload: "3;0;p=%0A;Alpha/") == nil)
        #expect(DirectoryCompletion(payload: "4;0;p=Other;Alpha/")?.previewSuffix == nil)
    }

}
