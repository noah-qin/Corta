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

    static func feed(_ body: String, _ performer: inout Performer) { performer.oscDispatch(Array(body.utf8)[...]) }

    @Test func vscodeAndConEmuUseTheSameCommandRecords() {
        func run(_ code: Int) -> Terminal {
            var terminal = Terminal(rows: 8, columns: 40)
            terminal.feed(Self.osc("\(code);A"))
            terminal.feed(Array("$ ".utf8)); terminal.feed(Self.osc("\(code);B"))
            terminal.feed(Array("echo hello\r\n".utf8)); terminal.feed(Self.osc("\(code);C"))
            terminal.feed(Array("hello\r\n".utf8)); terminal.feed(Self.osc("\(code);D;7"))
            return terminal
        }
        let native = run(133), vscode = run(633)
        #expect(native.grid.cursor == vscode.grid.cursor)
        #expect(native.commandRecords.records.map(\.exitStatus) == vscode.commandRecords.records.map(\.exitStatus))
        #expect(native.commandRecords.records.count == 1)
        var performer = Performer(grid: Grid(rows: 8, columns: 40))
        Self.feed("9;12", &performer)
        #expect(performer.state.promptRow == 0)
        Self.feed("633;E;not trusted;nonce", &performer)
        #expect(performer.state.commandRecords.records.count == 1)
        #expect(performer.state.outputBuffer.isEmpty)
    }

    @Test func hostlessDirectoriesRespectRemoteContext() {
        var performer = Performer(grid: Grid(rows: 4, columns: 20))
        Self.feed("1337;CurrentDir=/local", &performer)
        #expect(performer.state.workingDirectory == "/local")
        Self.feed("1337;RemoteHost=user@example.invalid", &performer)
        Self.feed("633;P;Cwd=/remote", &performer)
        #expect(performer.state.workingDirectory == "/local")
        #expect(performer.state.remoteContext?.host == "example.invalid")
        #expect(performer.state.remoteContext?.directory == "/remote")
        Self.feed("1337;CurrentDir=/other", &performer)
        #expect(performer.state.remoteContext?.directory == "/other")
        Self.feed("9;9;/unsafe", &performer)
        #expect(performer.state.workingDirectory == "/local")
        Self.feed("1337;RemoteHost=me@localhost", &performer)
        Self.feed("633;P;Cwd=/local-again", &performer)
        #expect(performer.state.remoteContext == nil)
        #expect(performer.state.workingDirectory == "/local-again")
    }

    @Test(arguments: [("0", CursorStyle.block), ("1", .bar), ("2", .underline)])
    func cursorShapes(value: String, expected: CursorStyle) {
        var terminal = Terminal()
        terminal.feed(Self.osc("1337;CursorShape=\(value)"))
        #expect(terminal.grid.cursorStyle == expected)
        #expect(terminal.grid.cursorStyleIsExplicit)
    }

    @Test func marksHistoryAttentionAndCellSize() {
        var performer = Performer(grid: Grid(rows: 2, columns: 20))
        Self.feed("1337;SetMark", &performer)
        #expect(performer.grid.line(atAbsoluteRow: 0)?.mark.isPrompt == true)
        performer.grid.lineFeed(); performer.grid.lineFeed()
        #expect(performer.grid.scrollback.count > 0)
        Self.feed("1337;ClearScrollback", &performer)
        #expect(performer.grid.scrollback.count == 0)
        Self.feed("1337;RequestAttention=once", &performer)
        #expect(performer.state.attention == .once)
        Self.feed("1337;RequestAttention=fireworks", &performer)
        #expect(performer.state.attention == .once)
        Self.feed("1337;RequestAttention=yes", &performer)
        #expect(performer.state.attention == .continuous)
        Self.feed("1337;RequestAttention=no", &performer)
        #expect(performer.state.attention == .cancel)
        performer.grid.cellPixelHeight = 40; performer.grid.cellPixelWidth = 20; performer.grid.backingScale = 2
        Self.feed("1337;ReportCellSize", &performer)
        #expect(
            String(decoding: performer.state.outputBuffer, as: UTF8.self)
                == "\u{1B}]1337;ReportCellSize=20.0;10.0;2.0\u{1B}\\")
    }

    @Test func colorsShareLegacyStateAndOnlyReplyWithFixedKeys() {
        var performer = Performer(grid: Grid(rows: 4, columns: 20))
        Self.feed("21;foreground=#123456;selection_background=#abcdef;cursor_text=#fff;42=#654321", &performer)
        #expect(performer.state.dynamicColors.foreground.red == 0x12)
        #expect(performer.state.selectionBackground == .rgb(0xab, 0xcd, 0xef))
        #expect(performer.state.dynamicColors.cursorText == .rgb(255, 255, 255))
        #expect(performer.state.indexedPalette.color(at: 42).red == 0x65)
        Self.feed("21;foreground=?;42=?;BAD\nKEY=?;cursor_text=?", &performer)
        let reply = String(decoding: performer.state.outputBuffer, as: UTF8.self)
        let colors = "foreground=rgb:1212/3434/5656;42=rgb:6565/4343/2121;cursor_text=rgb:ffff/ffff/ffff"
        #expect(reply == "\u{1B}]21;" + colors + "\u{1B}\\")
        Self.feed("21;foreground=;42=;cursor_text=;selection_background=", &performer)
        #expect(performer.state.dynamicColors.foreground == performer.state.dynamicColorDefaults.foreground)
        #expect(performer.state.dynamicColors.cursorText == .default)
        #expect(performer.state.selectionBackground == .default)
    }

    @Test func pointerStackIsCappedAndNamesAreNeverEchoed() {
        var terminal = Terminal()
        terminal.feed(Self.osc("22;pointer"))
        terminal.feed(Self.osc("22;>text,grab"))
        #expect(terminal.pointerShape == "grab")
        terminal.feed(Self.osc("22;?pointer,not-real,__current__,__default__"))
        #expect(terminal.takeOutput() == Self.osc("22;1,0,grab,default"))
        terminal.feed(Self.osc("22;<")); #expect(terminal.pointerShape == "text")
        terminal.feed(Array("\u{1B}[?1049h".utf8)); #expect(terminal.pointerShape == nil)
        terminal.feed(Self.osc("22;crosshair"))
        terminal.feed(Array("\u{1B}[?1049l".utf8)); #expect(terminal.pointerShape == "text")
        terminal.feed(Array("\u{1B}[?1049h".utf8)); #expect(terminal.pointerShape == "crosshair")
        terminal.feed(Array("\u{1B}[?1049l".utf8)); #expect(terminal.pointerShape == "text")
        terminal.feed(Self.osc("22;made-up")); #expect(terminal.pointerShape == "default")
        var stack = PointerShapeStack()
        for _ in 0..<100 { _ = stack.handle(">pointer") }
        #expect(stack.shapes.count == 16)
        terminal.feed(Array("\u{1B}c".utf8)); #expect(terminal.pointerShape == nil)
    }

    @Test func clipboardTransactionsSanitiseAndFailClosed() {
        var terminal = Terminal()
        terminal.feed(Self.osc("1337;Copy=:aGVsbG8="))
        #expect(terminal.takeClipboardCopy() == "hello")
        terminal.feed(Self.osc("5522;type=write"))
        terminal.feed(Self.osc("5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGVsbG8="))
        #expect(terminal.takeClipboardCopy() == nil)
        terminal.feed(Self.osc("5522;type=wdata"))
        #expect(terminal.takeClipboardCopy() == "hello")
        for bad in ["type=read", "type=wdata:mime=aW1hZ2UvcG5n;aGVsbG8=", "type=wdata:mime=dGV4dC9wbGFpbg==;???"] {
            terminal.feed(Self.osc("5522;type=write")); terminal.feed(Self.osc("5522;" + bad))
            terminal.feed(Self.osc("5522;type=wdata"))
            #expect(terminal.takeClipboardCopy() == nil)
        }
        terminal.feed(Self.osc("5522;type=write"))
        let chunk = Data(repeating: 65, count: 2048).base64EncodedString()
        for _ in 0..<2 { terminal.feed(Self.osc("5522;type=wdata:mime=dGV4dC9wbGFpbg==;" + chunk)) }
        terminal.feed(Self.osc("5522;type=wdata"))
        #expect(terminal.takeClipboardCopy() == nil)
        #expect(terminal.takeOutput().isEmpty)
    }

    @Test(arguments: ["3;x", "6;x", "46;log", "50;font", "51;x", "66;x", "106;x", "3008;x", "5113;x",
        "9;6;macro", "9;7;exec", "9;9;/path", "5522;type=read",
        "1337;StealFocus", "1337;SetProfile=x", "1337;SetBadgeFormat=eA==", "1337;ReportVariable=x", "1337;Custom=x",
        "1337;SetUserVar=x", "1337;ShellIntegrationVersion=1", "1337;HighlightCursorLine=yes", "1337;UnicodeVersion=9",
        "1337;SetKeyLabel=x", "1337;PushKeyLabels", "1337;PopKeyLabels", "1337;ClearCapturedOutput"])
    func deliberateNoOps(body: String) {
        var performer = Performer(grid: Grid(rows: 4, columns: 20))
        Self.feed(body, &performer)
        #expect(performer.grid.cursor.row == 0 && performer.grid.cursor.column == 0)
        #expect(performer.state.windowTitle == nil && performer.state.workingDirectory == nil)
        #expect(performer.state.pendingClipboardCopy == nil && performer.state.outputBuffer.isEmpty)
        #expect(performer.state.attention == nil && performer.state.programSignals.notification == nil)
        #expect(performer.grid.imagePlacements.imageCount == 0)
    }

    @Test func pngAndGifUseTheSharedPlacementTable() {
        for encoded in [Self.png, "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"] {
            var terminal = Terminal(rows: 10, columns: 40)
            terminal.grid.cellPixelWidth = 10; terminal.grid.cellPixelHeight = 20
            terminal.feed(Self.osc("1337;File=inline=1;width=4;height=4;preserveAspectRatio=0:" + encoded))
            let placement = terminal.grid.imagePlacements.orderedPlacements().first
            #expect(placement?.columns == 4 && placement?.rows == 4)
            #expect(placement?.displayPixelWidth == 40 && placement?.displayPixelHeight == 80)
            #expect(terminal.takeOutput().isEmpty)
            terminal.feed(Array("\u{1B}[2J".utf8))
            #expect(terminal.grid.imagePlacements.imageCount == 0)
        }
    }

    @Test func imageSizingAndMultipartBoundaries() {
        var terminal = Terminal(rows: 10, columns: 40)
        terminal.grid.cellPixelWidth = 10; terminal.grid.cellPixelHeight = 20
        terminal.feed(Self.osc("1337;MultipartFile=inline=1;width=50%;height=auto"))
        terminal.feed(Self.osc("1337;FilePart=" + Self.png.prefix(21)))
        terminal.feed(Self.osc("1337;FilePart=" + Self.png.dropFirst(21)))
        terminal.feed(Self.osc("1337;FileEnd"))
        let placement = terminal.grid.imagePlacements.orderedPlacements().first
        #expect(placement?.displayPixelWidth == 200 && placement?.displayPixelHeight == 200)
        #expect(placement?.columns == 20 && placement?.rows == 10)
    }

    @Test func imagesRefuseDownloadsTruncationAndAbandonedTransfers() {
        for body in ["1337;File=inline=0:" + Self.png, "1337;File=:" + Self.png,
            "1337;File=inline=1:" + Self.png.dropLast(), "1337;File=inline=1;size=999:" + Self.png] {
            var terminal = Terminal(); terminal.feed(Self.osc(body))
            #expect(terminal.grid.imagePlacements.imageCount == 0 && terminal.takeOutput().isEmpty)
        }
        var performer = Performer(grid: Grid(rows: 4, columns: 20))
        Self.feed("1337;MultipartFile=inline=1", &performer)
        Self.feed("1337;FilePart=" + Self.png, &performer)
        Self.feed("2;title", &performer)
        Self.feed("1337;FileEnd", &performer)
        #expect(performer.state.itermImage == nil && performer.grid.imagePlacements.imageCount == 0)
        performer.state.imageByteAllowance = 2
        Self.feed("1337;MultipartFile=inline=1", &performer)
        Self.feed("1337;FilePart=" + Self.png, &performer)
        #expect(performer.state.itermImage == nil)
        Self.feed("1337;MultipartFile=inline=1;size=67108865", &performer)
        #expect(performer.state.itermImage == nil)
    }

    @Test func imageOSCsCanExceedOrdinaryStringCapAndDefer() throws {
        var bytes = [UInt8](try #require(Data(base64Encoded: Self.png)))
        bytes += Array(repeating: 0, count: 80_000)
        var performer = Performer(grid: Grid(rows: 10, columns: 40))
        performer.defersLargeImageDecoding = true
        var parser = Parser()
        let source = Self.osc("1337;File=inline=1:" + Data(bytes).base64EncodedString()) + Array("after".utf8)
        let consumed = source.withUnsafeBufferPointer { _ in
            parser.parse(source[...], performer: &performer, stoppingAfterAPC: true)
        }
        #expect(consumed < source.count)
        let deferred = try #require(performer.state.deferredImage)
        performer.completeDeferredImage(deferred.decode())
        #expect(performer.grid.imagePlacements.imageCount == 1)
        #expect(performer.state.outputBuffer.isEmpty)
    }
}

extension OSCExtensionTests {
    @Test func vscodeEscapedDirectoriesAndMalformedValues() {
        var performer = Performer(grid: Grid(rows: 4, columns: 20))
        Self.feed(#"633;P;Cwd=/tmp/semi\x3bcolon\\folder"#, &performer)
        #expect(performer.state.workingDirectory == #"/tmp/semi;colon\folder"#)
        for value in [#"/tmp/\x0aevil"#, #"/tmp/\z"#, #"/tmp/\xZZ"#] {
            Self.feed("633;P;Cwd=" + value, &performer)
            #expect(performer.state.workingDirectory == #"/tmp/semi;colon\folder"#)
        }
    }

    @Test func multipartOverflowCancellationAndDimensionsFailClosed() {
        var terminal = Terminal()
        terminal.feed(Self.osc("1337;MultipartFile=inline=1"))
        terminal.feed(Self.osc("1337;FilePart=" + Self.png))
        terminal.feed(Self.osc("1337;FilePart=" + String(repeating: "A", count: 1024 * 1024)))
        terminal.feed(Self.osc("1337;FileEnd"))
        #expect(terminal.grid.imagePlacements.imageCount == 0)
        for control in [Array([UInt8(0x18)]), Array("\u{1B}[0m".utf8), Array("\u{1B}7".utf8)] {
            terminal.feed(Self.osc("1337;MultipartFile=inline=1"))
            terminal.feed(Self.osc("1337;FilePart=" + Self.png))
            terminal.feed(control)
            terminal.feed(Self.osc("1337;FileEnd"))
            #expect(terminal.grid.imagePlacements.imageCount == 0)
        }
        var bytes = [UInt8](Data(base64Encoded: Self.png)!)
        bytes[16] = 1 // width beyond side/pixel caps
        terminal.feed(Self.osc("1337;File=inline=1:" + Data(bytes).base64EncodedString()))
        #expect(terminal.grid.imagePlacements.imageCount == 0)
    }

    @Test func imageCellExtentIsClampedLikeKitty() {
        for preserve in ["1", "0"] {
            var terminal = Terminal(rows: 4, columns: 40)
            terminal.grid.cellPixelWidth = 10; terminal.grid.cellPixelHeight = 20
            terminal.feed(
                Self.osc(
                    "1337;File=inline=1;width=1000000px;height=1000000px;preserveAspectRatio=\(preserve):" + Self.png))
            let placement = terminal.grid.imagePlacements.orderedPlacements().first
            #expect(placement.map { ($0.columns ?? .max) <= 4096 && ($0.rows ?? .max) <= 4096 } == true,
                "preserve=\(preserve)")
        }
    }

    @Test func imagePixelSizingPreservesAspectAndHistoryErase() {
        var terminal = Terminal(rows: 4, columns: 40)
        terminal.grid.cellPixelWidth = 10; terminal.grid.cellPixelHeight = 20
        terminal.feed(Self.osc("1337;File=inline=1;width=30px;height=100px:" + Self.png))
        #expect(terminal.grid.imagePlacements.orderedPlacements().first?.displayPixelHeight == 30)
        terminal.feed(Array(String(repeating: "\r\n", count: 10).utf8))
        #expect(terminal.grid.imagePlacements.imageCount == 1)
        terminal.feed(Self.osc("1337;ClearScrollback"))
        #expect(terminal.grid.imagePlacements.imageCount == 0)
    }

    @Test func clipboardChunksCanSplitBase64AndOnlyFixedAcknowledgementIsQueued() throws {
        var terminal = Terminal()
        terminal.feed(Self.osc("5522;type=write"))
        for chunk in ["aG", "VsbG8="] {
            terminal.feed(Self.osc("5522;type=wdata:mime=dGV4dC9wbGFpbg==;" + chunk))
        }
        terminal.feed(Self.osc("5522;type=wdata"))
        let pendingCopy = terminal.takeClipboardCopyRequest()
        let copy = try #require(pendingCopy)
        #expect(copy.text == "hello")
        #expect(copy.acknowledgement == Self.osc("5522;type=write:status=DONE"))
        #expect(copy.refusal == Self.osc("5522;type=write:status=EPERM"))
        #expect(copy.failure == Self.osc("5522;type=write:status=EIO"))
        #expect(terminal.takeOutput().isEmpty) // host must first check permission and write
        #expect(terminal.takeClipboardCopyRequest() == nil)
    }

    @Test(arguments: ["legacy", "multipart", "gif"])
    func officialImgcatTranscript(kind: String) throws {
        let url = OSCCoverageTests.root.appendingPathComponent(
            "CortaTerminal/Tests/CortaTerminalTests/Golden/osc411-imgcat-\(kind).bin")
        var terminal = Terminal(rows: 10, columns: 40)
        terminal.grid.cellPixelWidth = 10; terminal.grid.cellPixelHeight = 20
        terminal.feed([UInt8](try Data(contentsOf: url)))
        #expect(terminal.grid.imagePlacements.placementCount == 1)
        #expect(
            terminal.grid.imagePlacements.orderedPlacements().first.flatMap {
                terminal.grid.imagePlacements.image($0.imageID)
            }?.format == (kind == "gif" ? .gif : .png))
        #expect(terminal.takeOutput().isEmpty)
    }

    @Test func officialVSCodeZshTranscriptHasNativeCommandRecords() throws {
        let url = OSCCoverageTests.root.appendingPathComponent(
            "CortaTerminal/Tests/CortaTerminalTests/Golden/osc411-vscode-zsh.bin")
        let bytes = try Data(contentsOf: url)
        var vscode = Terminal(rows: 24, columns: 80)
        vscode.feed([UInt8](bytes))
        var native = Terminal(rows: 24, columns: 80)
        native.feed(Self.osc("7;file://localhost/private/tmp"))
        let nativeText = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "]633;", with: "]133;")
        native.feed(Array(nativeText.utf8))
        let vscodeRecords = vscode.commandRecords.records.filter { $0.exitStatus != nil }
        let nativeRecords = native.commandRecords.records.filter { $0.exitStatus != nil }
        #expect(vscodeRecords.count == 1 && nativeRecords.count == 1)
        #expect(vscodeRecords.map(\.exitStatus) == nativeRecords.map(\.exitStatus))
        #expect(vscodeRecords.map(\.promptRow) == nativeRecords.map(\.promptRow))
        #expect(vscodeRecords.map(\.outputStartRow) == nativeRecords.map(\.outputStartRow))
        #expect(vscodeRecords.map(\.workingDirectory) == nativeRecords.map(\.workingDirectory))
        #expect(vscodeRecords.map(\.host) == nativeRecords.map(\.host))
        #expect(vscodeRecords.map(\.promptEndColumn) == nativeRecords.map(\.promptEndColumn))
        #expect(vscodeRecords.map(\.endRow) == nativeRecords.map(\.endRow))
        #expect(vscodeRecords.first?.exitStatus == 0)
    }
}
