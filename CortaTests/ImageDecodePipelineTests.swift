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
import Metal
import Testing

@testable import Corta
import CortaTerminal

/// Image decoding lives off the frame path. The frame path
/// (`texture(for:)`, `draw`) is a pure cache lookup; `update(table:...)`
/// only *schedules* decodes onto an injected scheduler; reused image ids
/// invalidate the texture decoded from the old bytes; and pruning runs even
/// when the last placement disappears.
@Suite("Image decode pipeline", .serialized, .metalSerialized)
struct ImageDecodePipelineTests {
    @Test("replacements and deletions do not orphan queued jobs")
    func replacementBacklogIsBoundedAndCoalesced() throws {
        let device = try #require(Self.makeDevice())
        let count = Counter()
        var work: [@Sendable () -> Void] = []
        let renderer = Self.makeRenderer(device: device, decodeCount: count) { work.append($0) }
        var terminal = Terminal(rows: 10, columns: 40)
        func update() {
            renderer.update(table: Self.table(of: terminal), rows: 10, offset: 0,
                scrollbackTotalPushed: 0, cellWidth: 10, cellHeight: 20)
        }
        for byte in UInt8(0)..<100 {
            Self.placeRGBA(&terminal, id: 1, byte: byte)
            update()
        }
        #expect(work.count == 1)
        work.removeFirst()()
        #expect(count.value == 0, "superseded bytes must not decode")
        update()
        #expect(work.count == 1)
        work.removeFirst()()
        #expect(count.value == 1)
        #expect(renderer.textureCount == 1)

        Self.placeRGBA(&terminal, id: 2, byte: 0)
        update()
        terminal.feed(Array("\u{1B}_Ga=d,d=i,i=2\u{1B}\\".utf8))
        update()
        work.removeFirst()()
        #expect(count.value == 1, "deleted queued image must not decode")
    }

    @Test("visible images over the pane budget wait instead of evicting each other every frame")
    func visibleOverflowDoesNotThrash() throws {
        let device = try #require(Self.makeDevice())
        let decodes = Counter()
        // 2×2 bgra = 16 bytes: the budget holds one of the two visible images.
        let renderer = KittyImageRenderer(
            device: device, textureByteBudget: 16,
            decodeImage: { data in
                decodes.value += 1
                return KittyImageRenderer.decode(data)
            },
            decodeScheduler: { $0() })
        var terminal = Terminal(rows: 10, columns: 40)
        Self.placeRGBA(&terminal, id: 1, byte: 1)
        Self.placeRGBA(&terminal, id: 2, byte: 2)
        func update() {
            renderer.update(table: Self.table(of: terminal), rows: 10, offset: 0,
                scrollbackTotalPushed: 0, cellWidth: 10, cellHeight: 20)
        }
        for _ in 0..<10 { update() }
        // Evicting a visible image to install the other re-decoded it on the
        // next frame, without end.
        #expect(decodes.value == 2, "each image decodes once; the overflow waits")
        #expect(renderer.textureCount == 1)

        // Room appears when the shown image goes: the waiting one installs.
        let shown: UInt32 = renderer.texture(for: KittyGraphics.ImageID(rawValue: 1)) != nil ? 1 : 2
        terminal.feed(Array("\u{1B}_Ga=d,d=i,i=\(shown)\u{1B}\\".utf8))
        update()
        update()
        #expect(renderer.texture(for: KittyGraphics.ImageID(rawValue: 3 - shown)) != nil)
        #expect(decodes.value == 3)
    }

    @Test("actual scheduled jobs are bounded across panes")
    func globalDecodeAdmissionIsBounded() throws {
        let device = try #require(Self.makeDevice())
        var work: [@Sendable () -> Void] = []
        let a = Self.makeRenderer(device: device, decodeCount: Counter()) { work.append($0) }
        let b = Self.makeRenderer(device: device, decodeCount: Counter()) { work.append($0) }
        var terminal = Terminal(rows: 10, columns: 40)
        for id in UInt32(1)...8 { Self.placeRGBA(&terminal, id: id, byte: 255) }
        for renderer in [a, b] {
            renderer.update(table: Self.table(of: terminal), rows: 10, offset: 0,
                scrollbackTotalPushed: 0, cellWidth: 10, cellHeight: 20)
        }
        #expect(work.count == 2)
        while !work.isEmpty { work.removeFirst()() }
        b.update(table: Self.table(of: terminal), rows: 10, offset: 0,
            scrollbackTotalPushed: 0, cellWidth: 10, cellHeight: 20)
        #expect(work.count == 2, "another pane retries after admission is released")
        while !work.isEmpty { work.removeFirst()() }
    }
    private static func makeDevice() -> MTLDevice? { MTLCreateSystemDefaultDevice() }

    /// Escaping closures mutate counters, so they need a reference — with a
    /// synchronous/captured scheduler nothing here actually races.
    private final class Counter: @unchecked Sendable {
        var value = 0
    }

    /// Transmits *and places* (`a=T`) a 2×2 RGBA image at the cursor, like
    /// `icat` does, and returns the terminal whose grid holds the table.
    private static func placeRGBA(
        _ terminal: inout Terminal, id: UInt32, byte: UInt8, control: String = ""
    ) {
        let payload = [UInt8](repeating: byte, count: 2 * 2 * 4)
        let suffix = control.isEmpty ? "" : ",\(control)"
        let command = "\u{1B}_Ga=T,i=\(id),f=32,s=2,v=2\(suffix);\(Data(payload).base64EncodedString())\u{1B}\\"
        terminal.feed(Array(command.utf8))
    }

    private static func table(of terminal: Terminal) -> ImagePlacementTable {
        terminal.grid.imagePlacements
    }

    private static func makeRenderer(
        device: MTLDevice,
        decodeCount: Counter,
        scheduled: @escaping (@escaping @Sendable () -> Void) -> Void
    ) -> KittyImageRenderer {
        KittyImageRenderer(
            device: device,
            decodeImage: { data in
                decodeCount.value += 1
                return KittyImageRenderer.decode(data)
            },
            decodeScheduler: scheduled)
    }

    private let updateArgs = (rows: 10, cellWidth: Float(10), cellHeight: Float(20))

    @Test("the frame path never decodes: update schedules, lookups only read")
    func framePathNeverDecodes() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let decodeCount = Counter()
        var work: [@Sendable () -> Void] = []
        let renderer = Self.makeRenderer(device: device, decodeCount: decodeCount) { work.append($0) }
        var terminal = Terminal(rows: 10, columns: 40)
        Self.placeRGBA(&terminal, id: 1, byte: 0xFF)
        let id = KittyGraphics.ImageID(rawValue: 1)

        // One update: the decode is scheduled, not performed, and a
        // frame-path lookup finds nothing yet — without decoding anything.
        renderer.update(
            table: Self.table(of: terminal), rows: updateArgs.rows, offset: 0,
            scrollbackTotalPushed: 0, cellWidth: updateArgs.cellWidth, cellHeight: updateArgs.cellHeight)
        #expect(work.count == 1)
        #expect(decodeCount.value == 0)
        #expect(renderer.texture(for: id) == nil)
        #expect(decodeCount.value == 0, "a frame-path lookup must never decode")

        // The scheduled work runs (off the frame path in production):
        // exactly one decode, then the texture exists.
        for item in work { item() }
        #expect(decodeCount.value == 1)
        #expect(renderer.texture(for: id) != nil)

        // Later frames are pure cache hits: no reschedule, no re-decode.
        renderer.update(
            table: Self.table(of: terminal), rows: updateArgs.rows, offset: 0,
            scrollbackTotalPushed: 0, cellWidth: updateArgs.cellWidth, cellHeight: updateArgs.cellHeight)
        #expect(work.count == 1)
        #expect(renderer.texture(for: id) != nil)
        #expect(decodeCount.value == 1)
    }

    @Test("a reused image id invalidates the texture decoded from the old bytes")
    func reusedImageIDInvalidatesOldTexture() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let decodeCount = Counter()
        let renderer = Self.makeRenderer(device: device, decodeCount: decodeCount) { $0() }
        var terminal = Terminal(rows: 10, columns: 40)
        let id = KittyGraphics.ImageID(rawValue: 1)

        Self.placeRGBA(&terminal, id: 1, byte: 0xFF)
        renderer.update(
            table: Self.table(of: terminal), rows: updateArgs.rows, offset: 0,
            scrollbackTotalPushed: 0, cellWidth: updateArgs.cellWidth, cellHeight: updateArgs.cellHeight)
        let first = try #require(renderer.texture(for: id))
        #expect(decodeCount.value == 1)

        // Same id, new transmission: the placement table's generation moved,
        // so the cached texture is stale and the image re-decodes once.
        Self.placeRGBA(&terminal, id: 1, byte: 0x7F)
        renderer.update(
            table: Self.table(of: terminal), rows: updateArgs.rows, offset: 0,
            scrollbackTotalPushed: 0, cellWidth: updateArgs.cellWidth, cellHeight: updateArgs.cellHeight)
        let second = try #require(renderer.texture(for: id))
        #expect(decodeCount.value == 2)
        #expect(first !== second)
    }

    @Test("deleting the last placement releases its texture and budget")
    func lastPlacementDisappearingReleasesTexture() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let renderer = Self.makeRenderer(device: device, decodeCount: Counter()) { $0() }
        var terminal = Terminal(rows: 10, columns: 40)
        Self.placeRGBA(&terminal, id: 1, byte: 0xFF)
        renderer.update(
            table: Self.table(of: terminal), rows: updateArgs.rows, offset: 0,
            scrollbackTotalPushed: 0, cellWidth: updateArgs.cellWidth, cellHeight: updateArgs.cellHeight)
        #expect(renderer.textureCount == 1)
        #expect(renderer.cachedTextureBytes == 16)

        // a=d,d=i — the image and its placements go away. Pruning must run
        // even though the table is now empty (a prune that bails out early
        // on an empty placement list leaks the texture).
        terminal.feed(Array("\u{1B}_Ga=d,d=i,i=1\u{1B}\\".utf8))
        renderer.update(
            table: Self.table(of: terminal), rows: updateArgs.rows, offset: 0,
            scrollbackTotalPushed: 0, cellWidth: updateArgs.cellWidth, cellHeight: updateArgs.cellHeight)
        #expect(renderer.textureCount == 0)
        #expect(renderer.cachedTextureBytes == 0)
    }

    @Test("a placement scrolled out of view is not decoded until it scrolls back")
    func offscreenPlacementIsNotDecoded() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let decodeCount = Counter()
        let renderer = Self.makeRenderer(device: device, decodeCount: decodeCount) { $0() }
        var terminal = Terminal(rows: 10, columns: 40)
        Self.placeRGBA(&terminal, id: 1, byte: 0xFF, control: "c=2,r=1")
        // Scroll the placement far above the viewport.
        terminal.feed(Array(String(repeating: "\r\n", count: 30).utf8))
        let scrollbackCount = terminal.grid.scrollback.count
        #expect(scrollbackCount >= 20)

        renderer.update(
            table: Self.table(of: terminal), rows: updateArgs.rows, offset: 0,
            scrollbackTotalPushed: terminal.grid.scrollback.totalPushed,
            cellWidth: updateArgs.cellWidth, cellHeight: updateArgs.cellHeight)
        #expect(decodeCount.value == 0, "a provably offscreen placement must not decode")
        #expect(renderer.textureCount == 0)

        // Scrolled all the way up, the placement is visible again and the
        // decode happens then.
        renderer.update(
            table: Self.table(of: terminal), rows: updateArgs.rows, offset: scrollbackCount,
            scrollbackTotalPushed: terminal.grid.scrollback.totalPushed,
            cellWidth: updateArgs.cellWidth, cellHeight: updateArgs.cellHeight)
        #expect(decodeCount.value == 1)
        #expect(renderer.textureCount == 1)
    }

    @Test("a decode failure is not retried per frame, but a re-transmission is")
    func failureIsPerTransmissionNotPermanent() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let decodeCount = Counter()
        let renderer = Self.makeRenderer(device: device, decodeCount: decodeCount) { $0() }
        var terminal = Terminal(rows: 10, columns: 40)
        // A corrupt PNG (f=100): stored by the core, fails the decode.
        terminal.feed(Array("\u{1B}_Ga=T,i=1,f=100;\(Data([UInt8](repeating: 0, count: 32)).base64EncodedString())\u{1B}\\".utf8))

        for _ in 0..<3 {
            renderer.update(
                table: Self.table(of: terminal), rows: updateArgs.rows, offset: 0,
                scrollbackTotalPushed: 0, cellWidth: updateArgs.cellWidth,
                cellHeight: updateArgs.cellHeight)
        }
        #expect(decodeCount.value == 1, "a failed image must not retry the decode every frame")
        #expect(renderer.textureCount == 0)

        // Same id, valid bytes this time: the failure was recorded per
        // transmission, so the re-transmission gets a fresh attempt.
        Self.placeRGBA(&terminal, id: 1, byte: 0xFF)
        renderer.update(
            table: Self.table(of: terminal), rows: updateArgs.rows, offset: 0,
            scrollbackTotalPushed: 0, cellWidth: updateArgs.cellWidth, cellHeight: updateArgs.cellHeight)
        #expect(decodeCount.value == 2)
        #expect(renderer.textureCount == 1)
    }

    @Test("a finished decode asks the shell for a frame")
    func decodeCompletionRequestsRedraw() throws {
        guard let device = Self.makeDevice() else {
            Issue.record("No Metal device available in this environment")
            return
        }
        let renderer = Self.makeRenderer(device: device, decodeCount: Counter()) { $0() }
        let notified = Counter()
        renderer.onImagesReady = { notified.value += 1 }
        var terminal = Terminal(rows: 10, columns: 40)
        Self.placeRGBA(&terminal, id: 1, byte: 0xFF)
        renderer.update(
            table: Self.table(of: terminal), rows: updateArgs.rows, offset: 0,
            scrollbackTotalPushed: 0, cellWidth: updateArgs.cellWidth, cellHeight: updateArgs.cellHeight)
        #expect(notified.value == 1)
        // A steady frame with nothing new does not notify again.
        renderer.update(
            table: Self.table(of: terminal), rows: updateArgs.rows, offset: 0,
            scrollbackTotalPushed: 0, cellWidth: updateArgs.cellWidth, cellHeight: updateArgs.cellHeight)
        #expect(notified.value == 1)
    }
}
