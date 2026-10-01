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

/// The kitty keyboard protocol's mode stack and its query.
@Suite("Kitty keyboard protocol")
struct KeyboardProtocolTests {
    private func response(to input: String) -> String {
        var terminal = Terminal(rows: 5, columns: 20)
        terminal.feed(Array(input.utf8))
        return String(decoding: terminal.takeOutput(), as: UTF8.self)
    }

    @Test("a program that pushes on the alternate screen and leaves with ?1049l alone restores the shell's keys")
    func alternateScreenHasItsOwnStack() {
        var terminal = Terminal(rows: 5, columns: 20)
        terminal.feed(Array("\u{1B}[?1049h\u{1B}[>1u".utf8))
        #expect(terminal.keyboardEnhancements == .disambiguate)
        // No pop: kitty's rule makes leaving the screen enough.
        terminal.feed(Array("\u{1B}[?1049l".utf8))
        #expect(terminal.keyboardEnhancements.isEmpty)
    }

    @Test("the main screen's flags survive a trip to the alternate screen")
    func mainStackIsParked() {
        var terminal = Terminal(rows: 5, columns: 20)
        terminal.feed(Array("\u{1B}[>1u\u{1B}[?1049h".utf8))
        #expect(terminal.keyboardEnhancements.isEmpty, "the alternate screen starts fresh")
        terminal.feed(Array("\u{1B}[?1049l".utf8))
        #expect(terminal.keyboardEnhancements == .disambiguate)
    }

    @Test("a finished command clears flags a program left pushed on the main screen")
    func commandEndClearsTheMainStack() {
        var terminal = Terminal(rows: 5, columns: 20)
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ ai\r\n\u{1B}]133;C\u{1B}\\\u{1B}[>1u".utf8))
        #expect(terminal.keyboardEnhancements == .disambiguate)
        // The program was killed without popping; the shell reports D.
        terminal.feed(Array("\u{1B}]133;D;137\u{1B}\\".utf8))
        #expect(terminal.keyboardEnhancements.isEmpty)
    }

    @Test("a fresh terminal reports the legacy encoding")
    func startsAtLegacy() {
        #expect(response(to: "\u{1B}[?u") == "\u{1B}[?0u")
    }

    @Test("a pushed flag is reported back")
    func pushIsReported() {
        #expect(response(to: "\u{1B}[>1u\u{1B}[?u") == "\u{1B}[?1u")
    }

    /// The report has to be the truth, not the request.
    @Test("flags Corta does not honour are not reported as honoured")
    func unsupportedFlagsAreNotClaimed() {
        #expect(response(to: "\u{1B}[>31u\u{1B}[?u") == "\u{1B}[?3u")
    }

    @Test("pop restores what the pusher found")
    func popRestores() {
        #expect(response(to: "\u{1B}[>1u\u{1B}[<1u\u{1B}[?u") == "\u{1B}[?0u")
    }

    @Test("popping past the base leaves the legacy encoding")
    func popPastTheBase() {
        #expect(response(to: "\u{1B}[<99u\u{1B}[?u") == "\u{1B}[?0u")
    }

    @Test("the set form's three modes replace, add and remove")
    func setModes() {
        #expect(response(to: "\u{1B}[=1;1u\u{1B}[?u") == "\u{1B}[?1u")
        #expect(response(to: "\u{1B}[=1;2u\u{1B}[?u") == "\u{1B}[?1u")
        #expect(response(to: "\u{1B}[=1;1u\u{1B}[=1;3u\u{1B}[?u") == "\u{1B}[?0u")
    }

    /// The stack is pushed by the byte stream, so it is unbounded input and
    /// needs a cap (`SECURITY.md` §3).
    @Test("the stack is bounded")
    func stackIsBounded() {
        var stack = KeyboardProtocolStack()
        for _ in 0..<1000 { stack.push(.disambiguate) }
        #expect(stack.depth <= KeyboardProtocolStack.maximumDepth)
        #expect(stack.current == .disambiguate)
    }
}
