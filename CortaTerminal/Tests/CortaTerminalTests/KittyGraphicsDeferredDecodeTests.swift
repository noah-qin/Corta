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

/// A large image's base64 and zlib run outside the session's lock: the
/// feed stops where the transmission ends, the decode runs unlocked, and
/// completing it stores, places and answers exactly as an inline decode
/// would have at that point in the stream.
@Suite("Kitty graphics, decoded outside the parse")
struct KittyGraphicsDeferredDecodeTests {
    /// `kitten icat`'s shape: 128 KiB base64 chunks, `a=T`, compressed.
    private static func transmission(id: Int, width: Int, height: Int) throws -> [UInt8] {
        // Noise, so the compressed payload stays past the deferral threshold.
        var seed: UInt32 = 1
        let raw = (0..<width * height * 4).map { _ -> UInt8 in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: seed >> 24)
        }
        let base64 = Array(Data(try KittyGraphicsCompressionTests.zlib(raw)).base64EncodedString().utf8)
        var stream: [UInt8] = []
        var offset = 0
        while offset < base64.count {
            let end = min(offset + 128 * 1024, base64.count)
            let more = end < base64.count ? 1 : 0
            let control = offset == 0 ? "a=T,i=\(id),f=32,s=\(width),v=\(height),o=z,c=4,r=2,m=\(more)" : "m=\(more)"
            stream += Array("\u{1B}_G\(control);".utf8) + base64[offset..<end] + Array("\u{1B}\\".utf8)
            offset = end
        }
        return stream
    }

    /// Where each placement sits, in order: `Placement` is not `Equatable`.
    private static func placements(_ grid: Grid) -> [String] {
        grid.imagePlacements.orderedPlacements().map { "\($0.imageID.rawValue)@\($0.row),\($0.column)" }
    }

    private static let before = Array("before\r\n".utf8)
    private static let after = Array("after\u{1B}[1;1HX".utf8)

    /// Feeds as the session does: stop, decode, complete, feed on.
    private static func feedDeferring(_ bytes: [UInt8], into terminal: inout Terminal) -> Int {
        var offset = 0
        var decodes = 0
        while offset < bytes.count {
            offset += terminal.feedDeferringImageDecode(bytes[offset...])
            if let deferred = terminal.takeDeferredImage() {
                decodes += 1
                terminal.completeDeferredImage(deferred.decode())
            }
        }
        return decodes
    }

    @Test("a large transmission stops the feed where it ends, with nothing after it applied")
    func largeTransmissionStopsTheFeed() throws {
        var terminal = Terminal(rows: 10, columns: 40)
        let image = try Self.transmission(id: 3, width: 256, height: 256)
        let stream = Self.before + image + Self.after
        let consumed = terminal.feedDeferringImageDecode(stream[...])
        // Right after the final chunk's terminator, in ground.
        #expect(consumed == Self.before.count + image.count)
        #expect(terminal.grid.imagePlacements.imageCount == 0)
        #expect(!terminal.grid.dump().contains("after"))
        #expect(terminal.takeDeferredImage() != nil)
    }

    @Test("completing a deferred decode leaves the grid, placement and reply an inline decode leaves")
    func deferredMatchesInline() throws {
        let stream = Self.before + (try Self.transmission(id: 3, width: 256, height: 256)) + Self.after
        var inline = Terminal(rows: 10, columns: 40)
        inline.grid.cellPixelWidth = 8
        inline.grid.cellPixelHeight = 16
        inline.feed(stream)
        var deferred = Terminal(rows: 10, columns: 40)
        deferred.grid.cellPixelWidth = 8
        deferred.grid.cellPixelHeight = 16
        #expect(Self.feedDeferring(stream, into: &deferred) == 1)

        #expect(deferred.grid.dump() == inline.grid.dump())
        #expect(deferred.grid.cursor == inline.grid.cursor)
        #expect(Self.placements(deferred.grid) == Self.placements(inline.grid))
        #expect(Self.placements(deferred.grid).count == 1)
        let id = KittyGraphics.ImageID(rawValue: 3)
        #expect(deferred.grid.imagePlacements.image(id)?.bytes == inline.grid.imagePlacements.image(id)?.bytes)
        #expect(deferred.takeOutput() == inline.takeOutput())
    }

    @Test("a refused large transmission answers the same error once decoded outside the parse")
    func refusalMatchesInline() throws {
        // Declares twice the pixels the payload inflates to.
        var stream = try Self.transmission(id: 9, width: 256, height: 256)
        let found = stream.firstRange(of: Array("s=256,v=256".utf8))
        let range = try #require(found)
        stream.replaceSubrange(range, with: Array("s=256,v=512".utf8))
        var inline = Terminal(rows: 10, columns: 40)
        inline.feed(stream)
        var deferred = Terminal(rows: 10, columns: 40)
        #expect(Self.feedDeferring(stream, into: &deferred) == 1)
        let reply = deferred.takeOutput()
        #expect(reply == inline.takeOutput())
        #expect(String(decoding: reply, as: UTF8.self).contains("EINVAL"))
        #expect(deferred.grid.imagePlacements.imageCount == 0)
    }

    @Test("a small transmission still decodes inline and never stops the feed")
    func smallTransmissionDecodesInline() {
        var terminal = Terminal(rows: 10, columns: 40)
        let payload = Data(repeating: 0xFF, count: 16).base64EncodedString()
        let stream = Array("\u{1B}_Ga=T,i=1,f=32,s=2,v=2;\(payload)\u{1B}\\".utf8) + Self.after
        #expect(terminal.feedDeferringImageDecode(stream[...]) == stream.count)
        #expect(terminal.takeDeferredImage() == nil)
        #expect(terminal.grid.imagePlacements.imageCount == 1)
    }

    @Test("a reset in the pause leaves nothing of the stopped sequence on screen")
    func resetInThePauseStrandsNothing() throws {
        var terminal = Terminal(rows: 10, columns: 40)
        let stream = (try Self.transmission(id: 3, width: 256, height: 256)) + Array("after".utf8)
        let consumed = terminal.feedDeferringImageDecode(stream[...])
        _ = terminal.takeDeferredImage()
        terminal.reset()
        _ = terminal.feedDeferringImageDecode(stream[consumed...])
        #expect(terminal.grid.dump().contains("after"))
        #expect(!terminal.grid.dump().contains("\\"))
    }

    @Test("a decode completed after a reset is dropped, unanswered")
    func resetDropsAPendingDecode() throws {
        var terminal = Terminal(rows: 10, columns: 40)
        let stream = try Self.transmission(id: 3, width: 256, height: 256)
        _ = terminal.feedDeferringImageDecode(stream[...])
        let taken = terminal.takeDeferredImage()
        let deferred = try #require(taken)
        terminal.reset()
        _ = terminal.takeOutput()
        terminal.completeDeferredImage(deferred.decode())
        #expect(terminal.grid.imagePlacements.imageCount == 0)
        #expect(terminal.takeOutput().isEmpty)
    }

    @Test("through a session, the image is placed and the text after it lands where it would inline")
    func sessionPlacesInStreamOrder() throws {
        let stream = Self.before + (try Self.transmission(id: 3, width: 256, height: 256)) + Array("after-END".utf8)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("corta-deferred-\(UUID().uuidString).bin")
        try Data(stream).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var inline = Terminal(rows: 10, columns: 40)
        inline.feed(stream)

        let session = try TerminalSession(
            executable: "/bin/cat", arguments: [file.path], size: TerminalSize(rows: 10, columns: 40))
        defer { session.stop() }
        session.start()
        let deadline = SuspendingClock.now + testTimeout(10)
        while !session.snapshot().dump().contains("after-END"), SuspendingClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let grid = session.snapshot()
        #expect(grid.dump().contains("after-END"))
        #expect(Self.placements(grid) == Self.placements(inline.grid))
        #expect(Self.placements(grid).count == 1)
        #expect(grid.cursor == inline.grid.cursor)
    }
}
