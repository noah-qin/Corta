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

/// DECSCUSR (`CSI Ps SP q`, xterm ctlseqs), driven through a
/// terminal because the parameter mapping is the performer's job.
@Suite("Cursor style")
struct CursorStyleTests {
    private func fed(_ input: String) -> Terminal {
        var terminal = Terminal(rows: 4, columns: 10)
        terminal.feed(input.utf8)
        return terminal
    }

    @Test("the default is a blinking block")
    func defaultIsBlinkingBlock() {
        #expect(fed("").grid.cursorStyle == .blinkingBlock)
    }

    /// xterm ctlseqs: 0 and 1 blinking block, 2 steady block, 3 blinking
    /// underline, 4 steady underline, 5 blinking bar, 6 steady bar.
    @Test("parameters map to the styles xterm documents", arguments: [
        ("\u{1B}[0 q", CursorStyle.blinkingBlock),
        ("\u{1B}[1 q", .blinkingBlock),
        ("\u{1B}[2 q", .block),
        ("\u{1B}[3 q", .blinkingUnderline),
        ("\u{1B}[4 q", .underline),
        ("\u{1B}[5 q", .blinkingBar),
        ("\u{1B}[6 q", .bar),
    ])
    func parameterMapsToStyle(_ input: String, _ style: CursorStyle) {
        #expect(fed(input).grid.cursorStyle == style)
    }

    @Test("an unknown parameter is ignored")
    func unknownParameterIsIgnored() {
        #expect(fed("\u{1B}[2 q\u{1B}[99 q").grid.cursorStyle == .block)
    }

    /// The style is global to the terminal: set on the alternate screen, it
    /// is still the style after switching back (xterm ctlseqs; DECSCUSR is
    /// not part of the ?1049 save/restore).
    @Test("the style survives an alternate-screen round trip")
    func styleSurvivesAlternateScreen() {
        #expect(fed("\u{1B}[?1049h\u{1B}[5 q\u{1B}[?1049l").grid.cursorStyle == .blinkingBar)
    }
}
