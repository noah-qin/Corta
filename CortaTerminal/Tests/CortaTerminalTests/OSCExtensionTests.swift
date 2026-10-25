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

@Suite("OSC ecosystems")
struct OSCExtensionTests {
    static func osc(_ body: String) -> [UInt8] { Array(("\u{1B}]" + body + "\u{1B}\\").utf8) }
    static let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
    static func feed(_ body: String, _ p: inout Performer) { p.oscDispatch(Array(body.utf8)[...]) }

    @Test func vscodeAndConEmuUseTheSameCommandRecords() {
        func run(_ code: Int) -> Terminal {
            var t = Terminal(rows: 8, columns: 40)
            t.feed(Self.osc("\(code);A"))
            t.feed(Array("$ ".utf8)); t.feed(Self.osc("\(code);B"))
            t.feed(Array("echo hello\r\n".utf8)); t.feed(Self.osc("\(code);C"))
            t.feed(Array("hello\r\n".utf8)); t.feed(Self.osc("\(code);D;7"))
            return t
        }
        let native = run(133), vscode = run(633)
        #expect(native.grid.cursor == vscode.grid.cursor)
        #expect(native.commandRecords.records.map(\.exitStatus) == vscode.commandRecords.records.map(\.exitStatus))
        #expect(native.commandRecords.records.count == 1)
        var p = Performer(grid: Grid(rows: 8, columns: 40))
        Self.feed("9;12", &p)
        #expect(p.state.promptRow == 0)
        Self.feed("633;E;not trusted;nonce", &p)
        #expect(p.state.commandRecords.records.count == 1)
        #expect(p.state.outputBuffer.isEmpty)
    }

    @Test func hostlessDirectoriesRespectRemoteContext() {
        var p = Performer(grid: Grid(rows: 4, columns: 20))
        Self.feed("1337;CurrentDir=/local", &p)
        #expect(p.state.workingDirectory == "/local")
        Self.feed("1337;RemoteHost=user@example.invalid", &p)
        Self.feed("633;P;Cwd=/remote", &p)
        #expect(p.state.workingDirectory == "/local")
        #expect(p.state.remoteContext?.host == "example.invalid")
        #expect(p.state.remoteContext?.directory == "/remote")
        Self.feed("1337;CurrentDir=/other", &p)
        #expect(p.state.remoteContext?.directory == "/other")
        Self.feed("9;9;/unsafe", &p)
        #expect(p.state.workingDirectory == "/local")
        Self.feed("1337;RemoteHost=me@localhost", &p)
        Self.feed("633;P;Cwd=/local-again", &p)
        #expect(p.state.remoteContext == nil)
        #expect(p.state.workingDirectory == "/local-again")
    }

    @Test(arguments: [("0", CursorStyle.block), ("1", .bar), ("2", .underline)])
    func cursorShapes(value: String, expected: CursorStyle) {
        var t = Terminal()
        t.feed(Self.osc("1337;CursorShape=\(value)"))
        #expect(t.grid.cursorStyle == expected)
        #expect(t.grid.cursorStyleIsExplicit)
    }
    @Test func marksHistoryAttentionAndCellSize() {
        var p = Performer(grid: Grid(rows: 2, columns: 20))
        Self.feed("1337;SetMark", &p)
        #expect(p.grid.line(atAbsoluteRow: 0)?.mark.isPrompt == true)
        p.grid.lineFeed(); p.grid.lineFeed()
        #expect(p.grid.scrollback.count > 0)
        Self.feed("1337;ClearScrollback", &p)
        #expect(p.grid.scrollback.count == 0)
        Self.feed("1337;RequestAttention=once", &p)
        #expect(p.state.attention == .once)
        Self.feed("1337;RequestAttention=fireworks", &p)
        #expect(p.state.attention == .once)
        Self.feed("1337;RequestAttention=yes", &p)
        #expect(p.state.attention == .continuous)
        Self.feed("1337;RequestAttention=no", &p)
        #expect(p.state.attention == .cancel)
        p.grid.cellPixelHeight = 40; p.grid.cellPixelWidth = 20; p.grid.backingScale = 2
        Self.feed("1337;ReportCellSize", &p)
        #expect(String(decoding: p.state.outputBuffer, as: UTF8.self) == "\u{1B}]1337;ReportCellSize=20.0;10.0;2.0\u{1B}\\")
    }

    @Test func colorsShareLegacyStateAndOnlyReplyWithFixedKeys() {
        var p = Performer(grid: Grid(rows: 4, columns: 20))
        Self.feed("21;foreground=#123456;selection_background=#abcdef;cursor_text=#fff;42=#654321", &p)
        #expect(p.state.dynamicColors.foreground.red == 0x12)
        #expect(p.state.selectionBackground == .rgb(0xab, 0xcd, 0xef))
        #expect(p.state.dynamicColors.cursorText == .rgb(255, 255, 255))
        #expect(p.state.indexedPalette.color(at: 42).red == 0x65)
        Self.feed("21;foreground=?;42=?;BAD\nKEY=?;cursor_text=?", &p)
        let reply = String(decoding: p.state.outputBuffer, as: UTF8.self)
        #expect(reply == "\u{1B}]21;foreground=rgb:1212/3434/5656;42=rgb:6565/4343/2121;cursor_text=rgb:ffff/ffff/ffff\u{1B}\\")
        Self.feed("21;foreground=;42=;cursor_text=;selection_background=", &p)
        #expect(p.state.dynamicColors.foreground == p.state.dynamicColorDefaults.foreground)
        #expect(p.state.dynamicColors.cursorText == .default)
        #expect(p.state.selectionBackground == .default)
    }
    @Test func pointerStackIsCappedAndNamesAreNeverEchoed() {
        var t = Terminal()
        t.feed(Self.osc("22;pointer"))
        t.feed(Self.osc("22;>text,grab"))
        #expect(t.pointerShape == "grab")
        t.feed(Self.osc("22;?pointer,not-real,__current__,__default__"))
        #expect(t.takeOutput() == Self.osc("22;1,0,grab,default"))
        t.feed(Self.osc("22;<")); #expect(t.pointerShape == "text")
        t.feed(Array("\u{1B}[?1049h".utf8)); #expect(t.pointerShape == nil)
        t.feed(Self.osc("22;crosshair"))
        t.feed(Array("\u{1B}[?1049l".utf8)); #expect(t.pointerShape == "text")
        t.feed(Array("\u{1B}[?1049h".utf8)); #expect(t.pointerShape == "crosshair")
        t.feed(Array("\u{1B}[?1049l".utf8)); #expect(t.pointerShape == "text")
        t.feed(Self.osc("22;made-up")); #expect(t.pointerShape == "default")
        var stack = PointerShapeStack()
        for _ in 0..<100 { _ = stack.handle(">pointer") }
        #expect(stack.shapes.count == 16)
        t.feed(Array("\u{1B}c".utf8)); #expect(t.pointerShape == nil)
    }
    @Test func clipboardTransactionsSanitiseAndFailClosed() {
        var t = Terminal()
        t.feed(Self.osc("1337;Copy=:aGVsbG8="))
        #expect(t.takeClipboardCopy() == "hello")
        t.feed(Self.osc("5522;type=write"))
        t.feed(Self.osc("5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGVsbG8="))
        #expect(t.takeClipboardCopy() == nil)
        t.feed(Self.osc("5522;type=wdata"))
        #expect(t.takeClipboardCopy() == "hello")
        for bad in ["type=read", "type=wdata:mime=aW1hZ2UvcG5n;aGVsbG8=", "type=wdata:mime=dGV4dC9wbGFpbg==;???"] {
            t.feed(Self.osc("5522;type=write")); t.feed(Self.osc("5522;" + bad))
            t.feed(Self.osc("5522;type=wdata"))
            #expect(t.takeClipboardCopy() == nil)
        }
        t.feed(Self.osc("5522;type=write"))
        let chunk = Data(repeating: 65, count: 2048).base64EncodedString()
        for _ in 0..<2 { t.feed(Self.osc("5522;type=wdata:mime=dGV4dC9wbGFpbg==;" + chunk)) }
        t.feed(Self.osc("5522;type=wdata"))
        #expect(t.takeClipboardCopy() == nil)
        #expect(t.takeOutput().isEmpty)
    }

    @Test(arguments: ["3;x", "6;x", "46;log", "50;font", "51;x", "66;x", "106;x", "3008;x", "5113;x",
        "9;6;macro", "9;7;exec", "9;9;/path", "5522;type=read",
        "1337;StealFocus", "1337;SetProfile=x", "1337;SetBadgeFormat=eA==", "1337;ReportVariable=x", "1337;Custom=x",
        "1337;SetUserVar=x", "1337;ShellIntegrationVersion=1", "1337;HighlightCursorLine=yes", "1337;UnicodeVersion=9",
        "1337;SetKeyLabel=x", "1337;PushKeyLabels", "1337;PopKeyLabels", "1337;ClearCapturedOutput"])
    func deliberateNoOps(body: String) {
        var p = Performer(grid: Grid(rows: 4, columns: 20))
        Self.feed(body, &p)
        #expect(p.grid.cursor.row == 0 && p.grid.cursor.column == 0)
        #expect(p.state.windowTitle == nil && p.state.workingDirectory == nil)
        #expect(p.state.pendingClipboardCopy == nil && p.state.outputBuffer.isEmpty)
        #expect(p.state.attention == nil && p.state.programSignals.notification == nil)
        #expect(p.grid.imagePlacements.imageCount == 0)
    }

    @Test func pngAndGifUseTheSharedPlacementTable() {
        for encoded in [Self.png, "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"] {
            var t = Terminal(rows: 10, columns: 40)
            t.grid.cellPixelWidth = 10; t.grid.cellPixelHeight = 20
            t.feed(Self.osc("1337;File=inline=1;width=4;height=4;preserveAspectRatio=0:" + encoded))
            let p = t.grid.imagePlacements.orderedPlacements().first
            #expect(p?.columns == 4 && p?.rows == 4)
            #expect(p?.displayPixelWidth == 40 && p?.displayPixelHeight == 80)
            #expect(t.takeOutput().isEmpty)
            t.feed(Array("\u{1B}[2J".utf8))
            #expect(t.grid.imagePlacements.imageCount == 0)
        }
    }
    @Test func imageSizingAndMultipartBoundaries() {
        var t = Terminal(rows: 10, columns: 40)
        t.grid.cellPixelWidth = 10; t.grid.cellPixelHeight = 20
        t.feed(Self.osc("1337;MultipartFile=inline=1;width=50%;height=auto"))
        t.feed(Self.osc("1337;FilePart=" + Self.png.prefix(21)))
        t.feed(Self.osc("1337;FilePart=" + Self.png.dropFirst(21)))
        t.feed(Self.osc("1337;FileEnd"))
        let p = t.grid.imagePlacements.orderedPlacements().first
        #expect(p?.displayPixelWidth == 200 && p?.displayPixelHeight == 200)
        #expect(p?.columns == 20 && p?.rows == 10)
    }
    @Test func imagesRefuseDownloadsTruncationAndAbandonedTransfers() {
        for body in ["1337;File=inline=0:" + Self.png, "1337;File=:" + Self.png,
            "1337;File=inline=1:" + Self.png.dropLast(), "1337;File=inline=1;size=999:" + Self.png] {
            var t = Terminal(); t.feed(Self.osc(body))
            #expect(t.grid.imagePlacements.imageCount == 0 && t.takeOutput().isEmpty)
        }
        var p = Performer(grid: Grid(rows: 4, columns: 20))
        Self.feed("1337;MultipartFile=inline=1", &p)
        Self.feed("1337;FilePart=" + Self.png, &p)
        Self.feed("2;title", &p)
        Self.feed("1337;FileEnd", &p)
        #expect(p.state.itermImage == nil && p.grid.imagePlacements.imageCount == 0)
        p.state.imageByteAllowance = 2
        Self.feed("1337;MultipartFile=inline=1", &p)
        Self.feed("1337;FilePart=" + Self.png, &p)
        #expect(p.state.itermImage == nil)
        Self.feed("1337;MultipartFile=inline=1;size=67108865", &p)
        #expect(p.state.itermImage == nil)
    }
    @Test func imageOSCsCanExceedOrdinaryStringCapAndDefer() throws {
        var bytes = [UInt8](try #require(Data(base64Encoded: Self.png)))
        bytes += Array(repeating: 0, count: 80_000)
        var p = Performer(grid: Grid(rows: 10, columns: 40))
        p.defersLargeImageDecoding = true
        var parser = Parser()
        let source = Self.osc("1337;File=inline=1:" + Data(bytes).base64EncodedString()) + Array("after".utf8)
        let consumed = source.withUnsafeBufferPointer { _ in
            parser.parse(source[...], performer: &p, stoppingAfterAPC: true)
        }
        #expect(consumed < source.count)
        let deferred = try #require(p.state.deferredImage)
        p.completeDeferredImage(deferred.decode())
        #expect(p.grid.imagePlacements.imageCount == 1)
        #expect(p.state.outputBuffer.isEmpty)
    }
    @Test func vscodeEscapedDirectoriesAndMalformedValues() {
        var p = Performer(grid: Grid(rows: 4, columns: 20))
        Self.feed(#"633;P;Cwd=/tmp/semi\x3bcolon\\folder"#, &p)
        #expect(p.state.workingDirectory == #"/tmp/semi;colon\folder"#)
        for value in [#"/tmp/\x0aevil"#, #"/tmp/\z"#, #"/tmp/\xZZ"#] {
            Self.feed("633;P;Cwd=" + value, &p)
            #expect(p.state.workingDirectory == #"/tmp/semi;colon\folder"#)
        }
    }
    @Test func multipartOverflowCancellationAndDimensionsFailClosed() {
        var t = Terminal()
        t.feed(Self.osc("1337;MultipartFile=inline=1"))
        t.feed(Self.osc("1337;FilePart=" + Self.png))
        t.feed(Self.osc("1337;FilePart=" + String(repeating: "A", count: 1024 * 1024)))
        t.feed(Self.osc("1337;FileEnd"))
        #expect(t.grid.imagePlacements.imageCount == 0)
        for control in [Array([UInt8(0x18)]), Array("\u{1B}[0m".utf8), Array("\u{1B}7".utf8)] {
            t.feed(Self.osc("1337;MultipartFile=inline=1"))
            t.feed(Self.osc("1337;FilePart=" + Self.png))
            t.feed(control)
            t.feed(Self.osc("1337;FileEnd"))
            #expect(t.grid.imagePlacements.imageCount == 0)
        }
        var bytes = [UInt8](Data(base64Encoded: Self.png)!)
        bytes[16] = 1 // width beyond side/pixel caps
        t.feed(Self.osc("1337;File=inline=1:" + Data(bytes).base64EncodedString()))
        #expect(t.grid.imagePlacements.imageCount == 0)
    }
    @Test func imagePixelSizingPreservesAspectAndHistoryErase() {
        var t = Terminal(rows: 4, columns: 40)
        t.grid.cellPixelWidth = 10; t.grid.cellPixelHeight = 20
        t.feed(Self.osc("1337;File=inline=1;width=30px;height=100px:" + Self.png))
        #expect(t.grid.imagePlacements.orderedPlacements().first?.displayPixelHeight == 30)
        t.feed(Array(String(repeating: "\r\n", count: 10).utf8))
        #expect(t.grid.imagePlacements.imageCount == 1)
        t.feed(Self.osc("1337;ClearScrollback"))
        #expect(t.grid.imagePlacements.imageCount == 0)
    }

    @Test func clipboardChunksCanSplitBase64AndOnlyFixedAcknowledgementIsQueued() throws {
        var t = Terminal()
        t.feed(Self.osc("5522;type=write"))
        for chunk in ["aG", "VsbG8="] {
            t.feed(Self.osc("5522;type=wdata:mime=dGV4dC9wbGFpbg==;" + chunk))
        }
        t.feed(Self.osc("5522;type=wdata"))
        let pendingCopy = t.takeClipboardCopyRequest()
        let copy = try #require(pendingCopy)
        #expect(copy.text == "hello")
        #expect(copy.acknowledgement == Self.osc("5522;type=write:status=DONE"))
        #expect(t.takeOutput().isEmpty) // host must first check permission and write
        #expect(t.takeClipboardCopyRequest() == nil)
    }
    @Test(arguments: ["legacy", "multipart", "gif"])
    func officialImgcatTranscript(kind: String) throws {
        let url = OSCCoverageTests.root.appendingPathComponent("CortaTerminal/Tests/CortaTerminalTests/Golden/osc411-imgcat-\(kind).bin")
        var t = Terminal(rows: 10, columns: 40)
        t.grid.cellPixelWidth = 10; t.grid.cellPixelHeight = 20
        t.feed([UInt8](try Data(contentsOf: url)))
        #expect(t.grid.imagePlacements.placementCount == 1)
        #expect(t.grid.imagePlacements.orderedPlacements().first.flatMap { t.grid.imagePlacements.image($0.imageID) }?.format == (kind == "gif" ? .gif : .png))
        #expect(t.takeOutput().isEmpty)
    }
    @Test func officialVSCodeZshTranscriptHasNativeCommandRecords() throws {
        let url = OSCCoverageTests.root.appendingPathComponent("CortaTerminal/Tests/CortaTerminalTests/Golden/osc411-vscode-zsh.bin")
        let bytes = try Data(contentsOf: url)
        var vscode = Terminal(rows: 24, columns: 80)
        vscode.feed([UInt8](bytes))
        var native = Terminal(rows: 24, columns: 80)
        native.feed(Self.osc("7;file://localhost/private/tmp"))
        let nativeText = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "]633;", with: "]133;")
        native.feed(Array(nativeText.utf8))
        let v = vscode.commandRecords.records.filter { $0.exitStatus != nil }
        let n = native.commandRecords.records.filter { $0.exitStatus != nil }
        #expect(v.count == 1 && n.count == 1)
        #expect(v.map(\.exitStatus) == n.map(\.exitStatus))
        #expect(v.map(\.promptRow) == n.map(\.promptRow))
        #expect(v.map(\.outputStartRow) == n.map(\.outputStartRow))
        #expect(v.map(\.workingDirectory) == n.map(\.workingDirectory))
        #expect(v.map(\.host) == n.map(\.host))
        #expect(v.map(\.promptEndColumn) == n.map(\.promptEndColumn))
        #expect(v.map(\.endRow) == n.map(\.endRow))
        #expect(v.first?.exitStatus == 0)
    }

}
