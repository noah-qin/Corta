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

/// What `kitten icat` sends, and where the cursor ends up after a placement,
/// held to kitty's own behaviour: 128 KiB chunks (`command.go`), and the
/// cursor moved right by the image's columns and down to its last row, the
/// next row past the right edge, the region scrolled past the bottom
/// (`graphics.c` `create_ref`, `screen.c` `screen_handle_graphics_command`).
@Suite("Kitty graphics chunk size and cursor movement")
struct KittyGraphicsCursorTests {
    private static func apc(_ control: String, payload: String = "") -> [UInt8] {
        Array("\u{1B}_G\(control);\(payload)\u{1B}\\".utf8)
    }

    /// A terminal whose pty reports 10 x 20-pixel cells, as the app does.
    private static func terminal(rows: Int = 10, columns: Int = 40) -> Terminal {
        var terminal = Terminal(rows: rows, columns: columns, scrollbackLimit: 100)
        terminal.grid.cellPixelWidth = 10
        terminal.grid.cellPixelHeight = 20
        return terminal
    }

    /// `width` x `height` RGBA, placed at the cursor quietly with no `c=`/`r=`.
    private static func place(width: Int, height: Int, extra: String = "") -> [UInt8] {
        let payload = Data(repeating: 0xFF, count: width * height * 4).base64EncodedString()
        return apc("a=T,q=2,f=32,s=\(width),v=\(height)\(extra)", payload: payload)
    }

    /// Bytes a PNG decoder would reject but whose `IHDR` names the size —
    /// all the core reads of a PNG.
    private static func pngLike(width: Int, height: Int, count: Int) -> Data {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]
        bytes += Array("IHDR".utf8)
        for value in [width, height] {
            bytes += [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }
        bytes += Array(repeating: 0, count: count - bytes.count)
        return Data(bytes)
    }

    private static func cursor(_ terminal: Terminal) -> [Int] {
        [terminal.grid.cursor.row, terminal.grid.cursor.column]
    }

    @Test("kitten icat's 128 KiB chunks arrive whole, unpadded, and place the image")
    func kittenSizedChunksArePlaced() throws {
        var terminal = Self.terminal()
        // Exactly what kitten 0.48 wrote for a 360x360 PNG: a first chunk of
        // 128 KiB of base64 with `m=1`, then the rest under `a=T,q=2` and no
        // `m=`, which ends it — unpadded, as kitten trims the `=`.
        let base64 = Array(Self.pngLike(width: 360, height: 360, count: 180_000).base64EncodedString().utf8)
        let unpadded = base64.prefix { $0 != UInt8(ascii: "=") }
        let first = String(decoding: unpadded.prefix(128 * 1024), as: UTF8.self)
        let rest = String(decoding: unpadded.dropFirst(128 * 1024), as: UTF8.self)
        #expect(first.utf8.count > 6144, "past the old cap, which dropped it")
        terminal.feed(Self.apc("a=T,q=2,f=100,m=1,s=360,v=360,X=7", payload: first))
        terminal.feed(Self.apc("a=T,q=2", payload: rest))
        terminal.feed(Array("\n".utf8))

        let placements = terminal.grid.imagePlacements.orderedPlacements()
        #expect(placements.count == 1)
        let image = try #require(placements.first.flatMap { terminal.grid.imagePlacements.image($0.imageID) })
        #expect(image.bytes.count == 180_000)
        // 360 px is 36 columns and 18 rows of 10 x 20: the cursor ends on
        // the last of those rows, icat's newline takes it to the one below.
        // Ten rows on screen, so the image scrolled up by nine.
        #expect(Self.cursor(terminal) == [9, 36])
        #expect(terminal.grid.scrollback.totalPushed == 9)
    }

    @Test("an APC chunk past the cap is dropped whole, and the stream resynchronises")
    func oversizedChunkIsDroppedAndParsingResumes() {
        var terminal = Self.terminal()
        let payload = String(repeating: "A", count: Parser.maxAPCStringLength)
        terminal.feed(Self.apc("a=T,f=32,s=1,v=1", payload: payload))
        terminal.feed(Array("ok".utf8))
        #expect(terminal.grid.imagePlacements.imageCount == 0)
        #expect(terminal.takeOutput().isEmpty, "never dispatched, so never answered")
        #expect(terminal.grid.rowText(0).hasPrefix("ok"))
    }

    @Test("with no c= or r=, the cursor moves by the pixel size over the cell size")
    func cursorMovesByPixelExtent() {
        var terminal = Self.terminal()
        terminal.feed(Array("\u{1B}[3;4H".utf8))  // row 2, column 3
        terminal.feed(Self.place(width: 25, height: 45))  // 3 columns, 3 rows
        #expect(Self.cursor(terminal) == [4, 6], "last row of the image, just right of it")
    }

    @Test("a one-row image leaves the cursor on its row, right of it")
    func oneRowImageMovesRight() {
        var terminal = Self.terminal()
        terminal.feed(Self.place(width: 20, height: 20))
        #expect(Self.cursor(terminal) == [0, 2])
    }

    @Test("an image reaching the right edge leaves the cursor at the start of the next row")
    func rightEdgeWrapsToNextRow() {
        var terminal = Self.terminal(columns: 20)
        terminal.feed(Array("\u{1B}[1;11H".utf8))  // column 10
        terminal.feed(Self.place(width: 100, height: 40))  // 10 columns, 2 rows
        #expect(Self.cursor(terminal) == [2, 0])
    }

    @Test("an image past the bottom scrolls the screen, and the image with it")
    func bottomScrollsTheScreen() {
        var terminal = Self.terminal(rows: 10)
        terminal.feed(Array("\u{1B}[9;1H".utf8))  // row 8
        terminal.feed(Self.place(width: 10, height: 100))  // 5 rows: rows 8–12
        #expect(Self.cursor(terminal) == [9, 1])
        #expect(terminal.grid.scrollback.totalPushed == 3)
        let placement = terminal.grid.imagePlacements.orderedPlacements()[0]
        let top = ScrollbackCoordinates.reanchoredRow(
            placement.row, from: placement.baseScrollbackTotal, to: terminal.grid.scrollback.totalPushed)
        #expect(top == 5, "the whole image still on screen, its last row the cursor's")
    }

    @Test("an image taller than the screen scrolls the whole way, leaving the cursor on its last row")
    func tallerThanScreenScrollsFully() {
        var terminal = Self.terminal(rows: 10)
        terminal.feed(Array("\u{1B}[9;1H".utf8))  // row 8
        terminal.feed(Self.place(width: 10, height: 400))  // 20 rows: 8–27
        #expect(Self.cursor(terminal) == [9, 1])
        #expect(terminal.grid.scrollback.totalPushed == 18, "more than one screen's height")
        let placement = terminal.grid.imagePlacements.orderedPlacements()[0]
        let top = ScrollbackCoordinates.reanchoredRow(
            placement.row, from: placement.baseScrollbackTotal, to: terminal.grid.scrollback.totalPushed)
        #expect(top + 20 - 1 == 9, "its last row is the cursor's, not below it")
    }

    @Test("inside a scroll region, the region scrolls and the rows below it stay")
    func scrollRegionScrollsOnlyTheRegion() {
        var terminal = Self.terminal(rows: 10)
        terminal.feed(Array("\u{1B}[10;1Hfooter\u{1B}[1;8r\u{1B}[7;1H".utf8))  // region rows 0–7, cursor row 6
        terminal.feed(Self.place(width: 10, height: 80))  // 4 rows: 6–9
        #expect(Self.cursor(terminal) == [7, 1])
        #expect(terminal.grid.scrollback.totalPushed == 0, "a partial region is not history")
        #expect(terminal.grid.rowText(9).hasPrefix("footer"))
    }

    @Test("full-screen index scrolling moves and clips images without history", arguments: [false, true])
    func fullScreenScrollingWithoutHistoryMovesImages(alternate: Bool) {
        var terminal = Terminal(rows: 6, columns: 20, scrollbackLimit: alternate ? 100 : 0)
        terminal.grid.cellPixelWidth = 10
        terminal.grid.cellPixelHeight = 20
        if alternate { terminal.feed(Array("\u{1B}[?1049h".utf8)) }
        terminal.feed(Array("\u{1B}[3;1H".utf8))
        terminal.feed(Self.place(width: 10, height: 60, extra: ",C=1"))
        terminal.feed(Array("\u{1B}[6;1H\n".utf8))
        var placements = terminal.grid.imagePlacements.orderedPlacements()
        #expect(placements.count == 1)
        #expect(placements.first?.row == 1)
        #expect(terminal.grid.scrollback.totalPushed == 0)

        terminal.feed(Array("\n\n".utf8))
        placements = terminal.grid.imagePlacements.orderedPlacements()
        #expect(placements.first?.row == 0)
        #expect(placements.first?.rows == 2)
        #expect(abs((placements.first?.sourceTop ?? -1) - Float(1) / 3) < 0.0001)
        terminal.feed(Array("\n\n".utf8))
        #expect(terminal.grid.imagePlacements.orderedPlacements().isEmpty)
    }

    @Test("explicit c= and r= win over the pixel size")
    func explicitCellsWin() {
        var terminal = Self.terminal()
        terminal.feed(Self.place(width: 10, height: 20, extra: ",c=4,r=3"))
        #expect(Self.cursor(terminal) == [2, 4])
    }

    @Test("C=1 leaves the cursor where it is")
    func cursorMovementSuppressed() {
        var terminal = Self.terminal()
        terminal.feed(Array("\u{1B}[3;4H".utf8))
        terminal.feed(Self.place(width: 25, height: 45, extra: ",C=1"))
        #expect(Self.cursor(terminal) == [2, 3])
        #expect(terminal.grid.imagePlacements.orderedPlacements().count == 1)
    }

    @Test("with no pixel size reported, and no c=/r=, the cursor is not guessed at")
    func unknownCellSizeLeavesCursor() {
        var terminal = Terminal(rows: 10, columns: 40)
        terminal.feed(Self.place(width: 25, height: 45))
        #expect(Self.cursor(terminal) == [0, 0])
    }

    @Test("a PNG with no s=/v= is measured from its IHDR")
    func pngMeasuredFromHeader() {
        var terminal = Self.terminal()
        let payload = Self.pngLike(width: 30, height: 60, count: 64).base64EncodedString()
        terminal.feed(Self.apc("a=T,q=2,f=100", payload: payload))
        #expect(Self.cursor(terminal) == [2, 3])
    }

    private static func rgba(_ width: Int, _ height: Int) -> KittyGraphics.ImageData {
        KittyGraphics.ImageData(
            format: .rgba, width: width, height: height, bytes: Array(repeating: 0xFF, count: width * height * 4))
    }

    @Test("an id-less image refused for its size evicts nothing")
    func refusedForDimensionsEvictsNothing() {
        var table = ImagePlacementTable()
        let first = table.storeAnonymous(Self.rgba(1, 1))
        #expect(first.refusal == nil)
        let huge = KittyGraphics.ImageData(
            format: .rgba, width: KittyGraphics.maximumImageDimension + 1, height: 1, bytes: [])
        #expect(table.storeAnonymous(huge).refusal == .dimensionsExceedCaps)
        #expect(table.image(first.id) != nil)
    }

    @Test("an id-less image that named images leave no room for evicts nothing")
    func refusedForBudgetEvictsNothing() {
        var table = ImagePlacementTable()
        table.maximumStoredBytes = 1000
        #expect(table.store(KittyGraphics.ImageID(rawValue: 1), data: Self.rgba(15, 15)) == nil)  // 900 bytes
        let small = table.storeAnonymous(Self.rgba(2, 2))  // 16 bytes
        #expect(small.refusal == nil)
        #expect(table.storeAnonymous(Self.rgba(5, 6)).refusal == .byteBudgetExceeded)  // 120: no room even without it
        #expect(table.image(small.id) != nil)
        let fits = table.storeAnonymous(Self.rgba(2, 11))  // 88: fits only once the 16 give way
        #expect(fits.refusal == nil)
        #expect(table.image(small.id) == nil)
    }
}
