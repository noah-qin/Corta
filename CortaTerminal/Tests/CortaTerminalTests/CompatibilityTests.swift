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

@Suite struct CompatibilityTests {
    private func feed(_ text: String, to terminal: inout Terminal) throws {
        terminal.feed(try Golden.decode(text))
    }
    @Test func titlesRestoreIndependentlyAndNeverReport() throws {
        var t = Terminal()
        try feed("\\e]0;both\\a\\e[22;0t\\e]1;icon\\a\\e]2;window\\a\\e[23;1t", to: &t)
        #expect(t.windowTitle == "window")
        try feed("\\e[23;2t\\e[20t\\e[21t", to: &t)
        #expect(t.windowTitle == "both")
        #expect(t.takeOutput().isEmpty)
        try feed("\\e[23;0t", to: &t)
        #expect(t.windowTitle == "both")
        var p = Performer(grid: Grid(rows: 2, columns: 4))
        p.oscDispatch(Array("0;base".utf8)[...])
        var parser = Parser()
        parser.parse(try Golden.decode("\\e[22;1t\\e]1;changed\\a\\e[23;1t"), performer: &p)
        #expect(p.state.iconName == "base")
        #expect(p.state.windowTitle == "base")
    }
    @Test func titleStacksAreBoundedAndReset() throws {
        var p = Performer(grid: Grid(rows: 2, columns: 4))
        var parser = Parser()
        for i in 0..<30 {
            parser.parse(try Golden.decode("\\e]0;\(i)\\a\\e[22;0t"), performer: &p)
        }
        #expect(p.state.windowTitleStack.count == 10)
        #expect(p.state.iconNameStack.count == 10)
        parser.parse(try Golden.decode("\\e[23;0t"), performer: &p)
        #expect(p.state.windowTitle == "29")
        for _ in 0..<9 { parser.parse(try Golden.decode("\\e[23;0t"), performer: &p) }
        #expect(p.state.windowTitle == "20")

        parser.parse(try Golden.decode("\\ec\\e[23;0t"), performer: &p)
        #expect(p.state.windowTitleStack.isEmpty)
        #expect(p.state.iconNameStack.isEmpty)
        #expect(p.state.windowTitle == nil)
    }
    @Test func dynamicColorsResetToCurrentThemeAndOverridesSurviveChanges() throws {
        var t = Terminal()
        var colors = DynamicColors(foreground: (1, 2, 3), background: (4, 5, 6), cursor: (7, 8, 9))
        colors.selection = (10, 11, 12)
        #expect(t.updateTheme(colors: colors, isDark: false).isEmpty)
        try feed(
            "\\e]10;#abcdef\\a\\e]11;#123456\\a\\e]12;#654321\\a\\e]17;#ff0000\\a\\e]19;#00ff00\\a",
            to: &t)
        #expect(t.selectionBackground == .rgb(255, 0, 0))
        #expect(t.selectionForeground == .rgb(0, 255, 0))
        colors.foreground = (9, 8, 7)
        _ = t.updateTheme(colors: colors, isDark: true)
        #expect(t.dynamicColors.foreground == (171, 205, 239))
        try feed("\\e]110\\a\\e]111;\\a\\e]112\\e\\\\\\e]117\\a\\e]119;\\a", to: &t)
        #expect(t.dynamicColors == colors)
        #expect(t.selectionBackground.isDefault)
        #expect(t.selectionForeground.isDefault)
        try feed("\\e]17;?\\a\\e]19;?\\a", to: &t)
        #expect(
            t.takeOutput()
                == Array("\u{1B}]17;rgb:0a0a/0b0b/0c0c\u{1B}\\\u{1B}]19;rgb:0909/0808/0707\u{1B}\\".utf8))
        try feed("\\e]13;?\\a\\e]14;red\\a\\e]15;?\\a\\e]16;?\\a\\e]18;?\\a", to: &t)
        #expect(t.takeOutput().isEmpty)
    }
    @Test func colorSchemeReportsExactlyOncePerChangeWhileSubscribed() throws {
        var t = Terminal()
        try feed("\\e[?996n\\e[?2031$p\\e[?2031h\\e[?2031$p", to: &t)
        #expect(t.takeOutput() == Array("\u{1B}[?997;1n\u{1B}[?2031;2$y\u{1B}[?2031;1$y".utf8))
        #expect(t.updateTheme(colors: DynamicColors(), isDark: false) == Array("\u{1B}[?997;2n".utf8))
        #expect(t.updateTheme(colors: DynamicColors(), isDark: false).isEmpty)
        #expect(t.updateTheme(colors: DynamicColors(), isDark: true) == Array("\u{1B}[?997;1n".utf8))
        try feed("\\e[?2031l", to: &t)
        #expect(t.updateTheme(colors: DynamicColors(), isDark: false).isEmpty)
        try feed("\\e[?996n\\ec\\e[?2031$p", to: &t)
        #expect(t.takeOutput().suffix(11) == Array("\u{1B}[?2031;2$y".utf8)[...])
    }
    @Test func xtgettcapRepliesAreExactConstantsAcrossEveryChunkBoundary() throws {
        let input = try Golden.decode("\\eP+q544e;436f;636f6c6f7273;524742;536d756c78\\e\\\\")
        let expected = Array(
            "\u{1B}P1+r544e=787465726d2d323536636f6c6f72\u{1B}\\\u{1B}P1+r436f=323536\u{1B}\\\u{1B}P1+r636f6c6f7273=323536\u{1B}\\\u{1B}P1+r524742=382f382f38\u{1B}\\\u{1B}P1+r536d756c78=1b5b343a25703125646d\u{1B}\\"
                .utf8)
        for split in 0...input.count {
            var t = Terminal()
            t.feed(input[..<split])
            t.feed(input[split...])
            #expect(t.takeOutput() == expected)
        }
    }
    @Test func unknownMalformedAbortedAndOversizedDCSNeverEcho() throws {
        for name in ["726d202d7266202f", "xyz", "5", "", "ffff"] {
            var t = Terminal()
            try feed("\\eP+q\(name)\\e\\\\", to: &t)
            #expect(t.takeOutput() == Array("\u{1B}P0+r\u{1B}\\".utf8))
        }
        for input in [
            "\\eP+q544e\\x18", "\\eP+q544e\\e[0m", "\\eP1+q544e\\e\\\\",
            "\\eP+q" + String(repeating: "4", count: 4096) + "\\e\\\\",
        ] {
            var t = Terminal()
            try feed(input + "ok", to: &t)
            #expect(t.takeOutput().isEmpty)
            #expect(t.grid.rowText(0).hasPrefix("ok"))
        }
    }
    @Test func renditionProbeReportsNumericStateWithoutEcho() throws {
        var t = Terminal()
        try feed("\\e[0m\\e[4:3m\\eP$qm\\e\\\\", to: &t)
        #expect(t.takeOutput() == Array("\u{1B}P1$r0;4:3m\u{1B}\\".utf8))
        try feed("\\e[1;3;38;5;2;48;2;1;2;3;58;5;9m\\eP$qm\\e\\\\", to: &t)
        #expect(t.takeOutput() == Array("\u{1B}P1$r0;1;3;4:3;38:5:2;48:2::1:2:3;58:5:9m\u{1B}\\".utf8))
        try feed("\\eP$qrm -rf /\\e\\\\", to: &t)
        #expect(t.takeOutput() == Array("\u{1B}P0$r\u{1B}\\".utf8))
    }

    @Test func themeChangesReachTheRealChildOnceEach() throws {
        let session = try TerminalSession(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "stty raw -echo; printf '\\033[?2031hREADY'; dd bs=1 count=18 2>/dev/null | od -An -tx1; printf DONE; sleep 30",
            ])
        defer { session.stop() }
        session.start()
        func wait(_ marker: String) -> String {
            let deadline = SuspendingClock.now + .seconds(5)
            var dump = ""
            repeat {
                dump = session.snapshot().dump()
                if dump.contains(marker) { return dump }
                Thread.sleep(forTimeInterval: 0.01)
            } while SuspendingClock.now < deadline
            return dump
        }
        try #require(wait("READY").contains("READY"))
        session.updateTheme(colors: DynamicColors(), isDark: false)
        session.updateTheme(colors: DynamicColors(), isDark: false)
        session.updateTheme(colors: DynamicColors(), isDark: true)
        let dump = wait("DONE")
        #expect(dump.contains("DONE"))
        let normalized = dump.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(normalized.contains("1b 5b 3f 39 39 37 3b 32 6e 1b 5b 3f 39 39 37 3b"))
        #expect(normalized.contains("31 6e"))
    }

    @Test func underlineColorsSurviveEditingReflowScreensAndCompression() throws {
        var t = Terminal(rows: 2, columns: 6, scrollbackLimit: 5000)
        try feed("\\e[4:3;58:2::255:0:0mabcdef\\e7\\e[59m\\e8", to: &t)
        let id = t.grid[0, 0].underlineColorID
        #expect(id != 0)
        #expect(t.grid.underlineColors.color(for: id) == .rgb(255, 0, 0))
        #expect(t.grid.pen.underlineColorID == id)
        t.resize(rows: 2, columns: 3)
        #expect(t.grid[0, 0].underlineColorID == id)
        try feed("\\e[?1049h\\e[58;5;2mX\\e[?1049l", to: &t)
        #expect(t.grid.underlineColors.color(for: id) == .rgb(255, 0, 0))
        try feed("\\e[2K", to: &t)
        #expect(t.grid[t.grid.cursor.row, 0].underlineColorID == 0)
        for _ in 0..<2048 { try feed("\\e[58;2;255;0;0mA\\r\\n", to: &t) }
        t.grid.scrollback.compressColdBatches()
        #expect(t.grid.scrollback.compressedBatchCount > 0)
        #expect(t.grid.scrollback.liveUnderlineColorIDs().contains(id))
        #expect(t.grid.scrollback[0].cells.contains { $0.underlineColorID == id })
        let snapshot = t.grid
        t.reset()
        #expect(snapshot.underlineColors.color(for: id) == .rgb(255, 0, 0))
        #expect(MemoryLayout<Cell>.stride == 16)
    }
    @Test func underlineTableReclaimsOnlyUnreferencedColors() throws {
        var grid = Grid(rows: 1, columns: 2)
        grid.setUnderlineColor(.rgb(255, 255, 255))
        grid.write(65)
        let kept = grid[0, 0].underlineColorID
        let snapshot = grid
        for value in 0..<5000 { grid.setUnderlineColor(.rgb(UInt8(value >> 8), UInt8(value & 255), 0)) }
        #expect(grid.underlineColors.count <= UnderlineColorTable.capacity)
        #expect(grid.underlineColors.color(for: kept) == .rgb(255, 255, 255))
        #expect(snapshot.underlineColors.color(for: kept) == .rgb(255, 255, 255))
    }
}
