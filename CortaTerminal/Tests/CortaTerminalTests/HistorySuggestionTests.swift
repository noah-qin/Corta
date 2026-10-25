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

struct HistorySuggestionTests {
    @Test func validatesSuffixAndRevealsConcealingCharacters() {
        #expect(HistorySuggestion(payload: "h;2;%20%E4%B8%AD%E6%96%87")?.suffix == " 中文")
        #expect(HistorySuggestion(payload: "h;3;a%E2%80%AEb%E2%80%8B")?.suffix == "a\u{FFFD}b\u{FFFD}")
        for payload in ["h;-1;text", "h;1;a;b", "h;1;%ZZ", "h;1;%0A", "h;1;%1B", "h;1;%C2%9B", "h;1;" + String(repeating: "a", count: 513)] {
            #expect(HistorySuggestion(payload: payload) == nil)
        }
        #expect(HistorySuggestion(payload: "h;1;" + String(repeating: "a", count: 512)) != nil)
        #expect(HistorySuggestion(payload: "h;1;")?.suffix == "")
    }

    @Test func onlyTokenedReportsCanShowOrClearTheHint() {
        var terminal = Terminal()
        func report(_ payload: String) -> [UInt8] { Array("\u{1b}]134;\(payload)\u{7}".utf8) }
        terminal.feed(report("h;1;secret"))
        #expect(terminal.historySuggestion == nil)
        terminal.directoryCompletionToken = "key"
        for payload in ["h;1;secret", "wrong;h;1;secret", "keyExtra;h;1;secret"] {
            terminal.feed(report(payload))
            #expect(terminal.historySuggestion == nil)
        }
        terminal.feed(report("key;h;2;%20status"))
        #expect(terminal.historySuggestion?.suffix == " status")
        terminal.feed(report("wrong;h;3;"))
        #expect(terminal.historySuggestion?.suffix == " status")
        terminal.feed(report("key;h;4;"))
        #expect(terminal.historySuggestion == nil)
        terminal.feed(report("key;h;5;" + String(repeating: "x", count: 513)))
        #expect(terminal.historySuggestion == nil)
        #expect(terminal.takeOutput().isEmpty, "display-only text is never a query response")
    }

    @Test func suggestionsAreExclusiveAndClearAcrossPromptAndScreenBoundaries() {
        var terminal = Terminal()
        terminal.directoryCompletionToken = "k"
        func feed(_ text: String) { terminal.feed(Array(text.utf8)) }
        let hint = "\u{1b}]134;k;h;1; status\u{7}"
        for boundary in ["\u{1b}]133;A\u{7}", "\u{1b}]133;B\u{7}", "\u{1b}]133;D;0\u{7}", "\u{1b}]133;C\u{7}", "\u{1b}[?1049h", "\u{1b}c"] {
            terminal.reset()
            feed(hint)
            #expect(terminal.historySuggestion != nil)
            feed(boundary)
            #expect(terminal.historySuggestion == nil)
        }
        terminal.reset()
        feed("\u{1b}]134;k;1;0;p=A;Alpha/\u{7}")
        #expect(terminal.directoryCompletion != nil)
        feed(hint)
        #expect(terminal.directoryCompletion == nil && terminal.historySuggestion != nil)
        feed("\u{1b}]134;k;2;0\u{7}")
        #expect(terminal.historySuggestion == nil)
        feed("\u{1b}]133;C\u{7}" + hint)
        #expect(terminal.historySuggestion == nil)
        terminal.reset()
        feed("\u{1b}[?1049h" + hint)
        #expect(terminal.historySuggestion == nil)
    }
}
