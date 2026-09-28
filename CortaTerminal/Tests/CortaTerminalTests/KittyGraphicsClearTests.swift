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

/// What erasing the display does to Kitty image placements, held to kitty's
/// own behaviour (`screen_erase_in_display` → `grman_clear`): `ED 2` deletes
/// every placement that reaches the visible screen and keeps the ones wholly
/// in scrollback; `ED 3` deletes the scrollback's; `ED 0`/`ED 1` delete
/// nothing. The image bytes always survive, so `a=p` can place them again.
@Suite("Kitty graphics and erasing the display")
struct KittyGraphicsClearTests {
    private static func apc(_ control: String, payload: String = "") -> [UInt8] {
        Array("\u{1B}_G\(control);\(payload)\u{1B}\\".utf8)
    }

    /// A 2x2 RGBA image with id `id`, placed at the cursor over `columns` x
    /// `rows` cells, quietly.
    private static func place(id: Int, columns: Int = 2, rows: Int = 2) -> [UInt8] {
        let payload = Data(repeating: 0xFF, count: 16).base64EncodedString()
        return apc("a=T,q=2,i=\(id),f=32,s=2,v=2,c=\(columns),r=\(rows)", payload: payload)
    }

    private static func placementIDs(_ terminal: Terminal) -> [UInt32] {
        terminal.grid.imagePlacements.orderedPlacements().map(\.imageID.rawValue)
    }

    @Test("ED 2 deletes a placement on the visible screen but keeps its image")
    func eraseAllDeletesAVisiblePlacement() {
        var terminal = Terminal(rows: 10, columns: 40)
        terminal.feed(Self.place(id: 1))
        #expect(Self.placementIDs(terminal) == [1])
        terminal.feed(Array("\u{1B}[H\u{1B}[2J".utf8))  // clear(1), and zsh's ^L
        #expect(Self.placementIDs(terminal).isEmpty)
        #expect(terminal.grid.imagePlacements.imageCount == 1, "the bytes stay for a=p")
    }

    @Test("ED 2 keeps a placement that lies wholly in scrollback")
    func eraseAllKeepsAPlacementInScrollback() {
        var terminal = Terminal(rows: 5, columns: 40, scrollbackLimit: 100)
        terminal.feed(Self.place(id: 1))  // rows 0–1; the cursor moves below it
        terminal.feed(Array(String(repeating: "\r\n", count: 12).utf8))  // well into history
        terminal.feed(Array("\u{1B}[2J".utf8))
        #expect(Self.placementIDs(terminal) == [1])
    }

    @Test("ED 2 deletes a placement anchored in scrollback that still reaches the screen")
    func eraseAllDeletesAPlacementStraddlingTheTop() {
        var terminal = Terminal(rows: 5, columns: 40, scrollbackLimit: 100)
        terminal.feed(Self.place(id: 1, rows: 4))  // rows 0–3; cursor to row 4
        terminal.feed(Array("\r\n\r\n".utf8))  // two rows into history: rows -2…1 now
        terminal.feed(Array("\u{1B}[2J".utf8))
        #expect(Self.placementIDs(terminal).isEmpty)
    }

    @Test("ED 3 deletes the placements in scrollback and keeps the screen's")
    func eraseScrollbackDeletesHistoryPlacements() {
        var terminal = Terminal(rows: 5, columns: 40, scrollbackLimit: 100)
        terminal.feed(Self.place(id: 1))
        terminal.feed(Array(String(repeating: "\r\n", count: 12).utf8))
        terminal.feed(Self.place(id: 2))  // on screen
        terminal.feed(Array("\u{1B}[3J".utf8))
        #expect(Self.placementIDs(terminal) == [2])
    }

    @Test("ED 0 and ED 1 delete no placement")
    func partialErasesKeepPlacements() {
        var terminal = Terminal(rows: 10, columns: 40)
        terminal.feed(Array("\u{1B}[5;1H".utf8))
        terminal.feed(Self.place(id: 1))
        terminal.feed(Array("\u{1B}[1;1H\u{1B}[0J\u{1B}[10;1H\u{1B}[1J".utf8))
        #expect(Self.placementIDs(terminal) == [1])
    }

    @Test("the app's Clear Screen deletes the visible placements too")
    func clearScreenDeletesVisiblePlacements() {
        var terminal = Terminal(rows: 10, columns: 40)
        terminal.feed(Self.place(id: 1))
        var grid = terminal.grid
        grid.clearScreen()
        #expect(grid.imagePlacements.orderedPlacements().isEmpty)
    }

    // MARK: - No r=: the height comes from pixels

    /// A 1-pixel-wide image `height` pixels tall, placed with no `c=`/`r=`,
    /// so its rows come from its pixels and the cell height.
    private static func placeRaw(id: Int, height: Int) -> [UInt8] {
        let payload = Data(repeating: 0xFF, count: height * 4).base64EncodedString()
        return apc("a=T,q=2,i=\(id),f=32,s=1,v=\(height)", payload: payload)
    }

    /// The first 33 bytes of a PNG — signature and `IHDR` — declaring
    /// `height`: all the core reads. The app's decoder is never reached.
    private static func placePNG(id: Int, height: Int) -> [UInt8] {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]
        bytes += Array("IHDR".utf8)
        bytes += [0, 0, 0, 1]  // width
        bytes += [UInt8(height >> 24 & 0xFF), UInt8(height >> 16 & 0xFF), UInt8(height >> 8 & 0xFF), UInt8(height & 0xFF)]
        bytes += [8, 6, 0, 0, 0, 0, 0, 0, 0]
        return apc("a=T,q=2,i=\(id),f=100", payload: Data(bytes).base64EncodedString())
    }

    /// Anchored at row 0, then `scrolled` rows pushed into history.
    private static func straddling(_ placement: [UInt8], scrolled: Int, cellPixelHeight: Int) -> Terminal {
        var terminal = Terminal(rows: 5, columns: 40, scrollbackLimit: 100)
        terminal.grid.cellPixelHeight = cellPixelHeight
        terminal.feed(placement)
        terminal.feed(Array("\u{1B}[5;1H".utf8))  // bottom row
        terminal.feed(Array(String(repeating: "\n", count: scrolled).utf8))
        return terminal
    }

    @Test("with no r=, a raw image's v= and the cell height say whether it reaches the screen")
    func rawHeightDecidesWithoutRows() {
        // 40 px at 10 px a row is 4 rows: two rows into history, rows -2…1.
        var reaching = Self.straddling(Self.placeRaw(id: 1, height: 40), scrolled: 2, cellPixelHeight: 10)
        reaching.feed(Array("\u{1B}[2J".utf8))
        #expect(Self.placementIDs(reaching).isEmpty)
        // Scrolled four rows: rows -4…-1, wholly in history.
        var past = Self.straddling(Self.placeRaw(id: 1, height: 40), scrolled: 4, cellPixelHeight: 10)
        past.feed(Array("\u{1B}[2J".utf8))
        #expect(Self.placementIDs(past) == [1])
    }

    @Test("with no r=, a PNG's height is read from its IHDR")
    func pngHeightDecidesWithoutRows() {
        var reaching = Self.straddling(Self.placePNG(id: 1, height: 40), scrolled: 2, cellPixelHeight: 10)
        #expect(Self.placementIDs(reaching) == [1], "the PNG must place without a declared size")
        reaching.feed(Array("\u{1B}[2J".utf8))
        #expect(Self.placementIDs(reaching).isEmpty)
        var past = Self.straddling(Self.placePNG(id: 1, height: 40), scrolled: 4, cellPixelHeight: 10)
        past.feed(Array("\u{1B}[2J".utf8))
        #expect(Self.placementIDs(past) == [1])
    }

    @Test("with no r= and no cell size, on screen goes and in history stays")
    func unknownHeightFallsBackToTheAnchor() {
        var onScreen = Terminal(rows: 5, columns: 40)
        onScreen.feed(Self.placeRaw(id: 1, height: 40))
        onScreen.feed(Array("\u{1B}[2J".utf8))
        #expect(Self.placementIDs(onScreen).isEmpty)
        var inHistory = Self.straddling(Self.placeRaw(id: 1, height: 40), scrolled: 2, cellPixelHeight: 0)
        inHistory.feed(Array("\u{1B}[2J".utf8))
        #expect(Self.placementIDs(inHistory) == [1])
    }

    @Test("the app's Clear History deletes the placements anchored in history")
    func clearHistoryDeletesHistoryPlacements() {
        var terminal = Terminal(rows: 5, columns: 40, scrollbackLimit: 100)
        terminal.feed(Self.place(id: 1))
        terminal.feed(Array(String(repeating: "\r\n", count: 12).utf8))
        terminal.feed(Self.place(id: 2))
        var grid = terminal.grid
        grid.clearScrollback()
        #expect(grid.imagePlacements.orderedPlacements().map(\.imageID.rawValue) == [2])
    }

    @Test("the cell height survives the alternate screen and a reset")
    func cellHeightSurvivesScreenChanges() {
        var terminal = Terminal(rows: 5, columns: 40)
        terminal.grid.cellPixelHeight = 17
        terminal.feed(Array("\u{1B}[?1049h\u{1B}[?1049l".utf8))
        #expect(terminal.grid.cellPixelHeight == 17)
        terminal.reset()
        #expect(terminal.grid.cellPixelHeight == 17)
    }

    @Test("a winsize reports its cell height")
    func winsizeCellHeight() {
        #expect(TerminalSize(rows: 30, columns: 120, pixelWidth: 1680, pixelHeight: 1020).cellPixelHeight == 34)
        #expect(TerminalSize(rows: 30, columns: 120).cellPixelHeight == 0)
    }
}

